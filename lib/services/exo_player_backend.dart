// v2.2.0: ExoPlayer (AndroidX Media3) 版本的 [PlayerBackend] 实现.
//
// v2.3.11 重大改动: 真正替换 video_player Flutter package, 改用自研
//   [CustomExoPlayer] (Kotlin MethodChannel + SurfaceTexture 输出).
//   video_player 整个包从 pubspec.yaml 移除.
//
//   为什么:
//   - video_player Dart 端只暴露 VideoPlayerController 抽象, 内部
//     ExoPlayer 的 DefaultLoadControl (min=15s/max=50s/fp=2.5s/
//     fp_re=5s) 没法从 Dart 配.
//   - 用户反馈 "卡顿时 buffer 时间短, 频繁 rebuffer" 是这个根因.
//     想加长 buffer, 必须直接配 ExoPlayer.
//   - 之前 v2.2.0 ~ v2.3.10 走 video_player, 自研 CustomExoPlayer
//     只是 building block. v2.3.11 真正接管.
//
//   现在:
//   - 走 [CustomExoPlayer] 调原生 ExoPlayer, buffer 配置:
//       minBufferMs=30s / maxBufferMs=90s
//       bufferForPlaybackMs=5s / bufferForPlaybackAfterRebufferMs=8s
//   - 视频输出走 Flutter SurfaceTexture (TextureRegistry), Dart 用
//     [Texture] widget 渲染. 见 [exo_player_view.dart].
//   - 状态同步走 EventChannel (CustomExoPlayer.events), 不再依赖
//     video_player VideoPlayerValue listener. position/duration/isPlaying/
//     isBuffering/videoWidth/videoHeight 全部从原生推过来.
//
//   v2.3.0 视频加速 (VideoProxyServer / CfOptimizer) 整个删了, 跟现在无关.

import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:luna_tv/services/custom_exo_player.dart';
import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/player_backend.dart';

class ExoPlayerBackend implements PlayerBackend {
  // ── 内部 CustomExoPlayer state ────────────────────────
  CustomExoPlayerHandle? _handle;
  StreamSubscription<Map<String, dynamic>>? _eventSub;
  // v2.3.11: position 由 Dart 端 200ms 轮询拿 (ExoPlayer 没有 dart 端
  //   listener 直接推 currentPosition, 跟 video_player VideoPlayerValue
  //   不一样). duration / isPlaying / isBuffering 走 EventChannel.
  Timer? _positionTimer;
  int _lastPositionMs = 0;

  // ── 缓存的状态 ────────────────────────────────────────
  bool _isPlaying = false;
  bool _isBuffering = false;
  bool _isCompleted = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double _volume = 1.0;
  double _speed = 1.0;
  int _width = 0;
  int _height = 0;

  // ── 流控制器 (broadcast 多订阅) ────────────────────────
  final _playingCtl = StreamController<bool>.broadcast();
  final _bufferingCtl = StreamController<bool>.broadcast();
  final _completedCtl = StreamController<bool>.broadcast();
  final _positionCtl = StreamController<Duration>.broadcast();
  final _durationCtl = StreamController<Duration>.broadcast();
  final _bandwidthCtl = StreamController<BandwidthSample>.broadcast();

  // ── 内部辅助 ────────────────────────────────────────
  bool _disposed = false;
  String? _currentUrl;

  ExoPlayerBackend();

  /// v2.3.11: 工厂 — 创建 CustomExoPlayer + 订阅 events.
  static Future<ExoPlayerBackend> create({
    Map<String, String>? defaultHeaders,
  }) async {
    final backend = ExoPlayerBackend();
    backend._init();
    DiaryService.add(
        '[ExoPlayer] init OK: custom=true, defaultBuffer=30s/90s/5s/8s, headers=${defaultHeaders?.keys.join(",") ?? "none"}');
    return backend;
  }

  void _init() {
    // 订阅 EventChannel (CustomExoPlayer.events), 同步 isPlaying /
    //   isBuffering / duration / videoSize 状态. position 走 200ms 轮询.
    _eventSub = CustomExoPlayer.events.listen(_onNativeState);
    _positionTimer = Timer.periodic(const Duration(milliseconds: 200),
        (_) => _pollPosition());
  }

  void _onNativeState(Map<String, dynamic> state) {
    if (_disposed) return;
    final handle = _handle;
    if (handle == null) return;
    final pid = state['playerId'];
    if (pid is! int || pid != handle.playerId) return;

    final isPlaying = state['isPlaying'] == true;
    final isBuffering = state['isBuffering'] == true;
    final durMs = (state['durationMs'] as num?)?.toInt() ?? 0;
    final w = (state['videoWidth'] as num?)?.toInt() ?? 0;
    final h = (state['videoHeight'] as num?)?.toInt() ?? 0;

    if (isPlaying != _isPlaying) {
      _isPlaying = isPlaying;
      _safeAdd(_playingCtl, isPlaying);
    }
    if (isBuffering != _isBuffering) {
      _isBuffering = isBuffering;
      _safeAdd(_bufferingCtl, isBuffering);
    }
    if (durMs > 0) {
      final dur = Duration(milliseconds: durMs);
      if (dur != _duration) {
        _duration = dur;
        _safeAdd(_durationCtl, dur);
      }
    }
    if (w != _width || h != _height) {
      _width = w;
      _height = h;
    }
  }

  Future<void> _pollPosition() async {
    if (_disposed) return;
    final handle = _handle;
    if (handle == null) return;
    // v2.3.11: 直接调 getState 拿 position 跟 duration. 200ms 一次,
    //   每次跨 thread 调一次原生, 跟 video_player 内部 100ms listener
    //   差不多频率. 状态 eventChannel 已经推过来时, _position/_duration
    //   已经是最新, getState 不会再发新值 (事件层 isPlaying / isBuffering
    //   推到 broadcast stream, position 推 positionStream).
    try {
      final s = await CustomExoPlayer.getState(handle.playerId);
      if (s == null || _disposed) return;
      // v2.3.11: 重新检查 handle 防止 race (await 期间 dispose)
      final cur = _handle;
      if (cur == null || cur.playerId != handle.playerId) return;
      if (s.positionMs != _lastPositionMs) {
        _lastPositionMs = s.positionMs;
        _position = Duration(milliseconds: s.positionMs);
        _safeAdd(_positionCtl, _position);
        // 推断 completed (跟 video_player VideoPlayerValue.isCompleted 行为对齐)
        if (_duration > Duration.zero &&
            _position >= _duration - const Duration(milliseconds: 500) &&
            !_isCompleted) {
          _isCompleted = true;
          _safeAdd(_completedCtl, true);
        } else if (_isCompleted && _position < _duration - const Duration(seconds: 2)) {
          // 重新 seek 回去, 清 completed
          _isCompleted = false;
          _safeAdd(_completedCtl, false);
        }
      }
      if (s.error.isNotEmpty) {
        DiaryService.add('[ExoPlayer] ERROR: ${s.error}');
        if (!_isCompleted) {
          _isCompleted = true;
          _safeAdd(_completedCtl, true);
        }
      }
    } catch (_) {
      // getState 失败 (player 已 release) 静默忽略
    }
  }

  Future<void> _ensurePlayer(String url) async {
    if (_disposed) {
      throw StateError('ExoPlayerBackend disposed');
    }
    if (_handle != null && _currentUrl == url) {
      // 同一个 URL 复用, 不重建
      return;
    }
    // 释放旧的 (texture 也会跟着释放, 旧 textureId 失效)
    final old = _handle;
    if (old != null) {
      try {
        await CustomExoPlayer.release(old.playerId);
      } catch (_) {}
      _handle = null;
    }
    final h = await CustomExoPlayer.create(
      minBufferMs: CustomExoPlayer.defaultMinBufferMs,
      maxBufferMs: CustomExoPlayer.defaultMaxBufferMs,
      bufferForPlaybackMs: CustomExoPlayer.defaultBufferForPlaybackMs,
      bufferForPlaybackAfterRebufferMs:
          CustomExoPlayer.defaultBufferForPlaybackAfterRebufferMs,
      withTexture: true,
    );
    if (_disposed) {
      // dispose 在 create 期间发生, 立即释放
      try {
        await CustomExoPlayer.release(h.playerId);
      } catch (_) {}
      throw StateError('ExoPlayerBackend disposed during create');
    }
    _handle = h;
    _currentUrl = url;
    _width = 0;
    _height = 0;
    _duration = Duration.zero;
    _position = Duration.zero;
    _lastPositionMs = 0;
  }

  // ── PlayerBackend 实现 ────────────────────────────────────
  @override
  bool get isPlaying => _isPlaying;
  @override
  bool get isBuffering => _isBuffering;
  @override
  bool get isCompleted => _isCompleted;
  @override
  Duration get position => _position;
  @override
  Duration get duration => _duration;
  @override
  double get volume => _volume;
  @override
  double get speed => _speed;
  @override
  int get width => _width;
  @override
  int get height => _height;

  @override
  Stream<bool> get playingStream => _playingCtl.stream;
  @override
  Stream<bool> get bufferingStream => _bufferingCtl.stream;
  @override
  Stream<Duration> get positionStream => _positionCtl.stream;
  @override
  Stream<Duration> get durationStream => _durationCtl.stream;
  @override
  Stream<bool> get completedStream => _completedCtl.stream;
  @override
  Stream<BandwidthSample> get bandwidthStream => _bandwidthCtl.stream;

  @override
  Future<void> open(
    String url, {
    Map<String, String>? headers,
    Duration? startAt,
  }) async {
    _isCompleted = false;
    _safeAdd(_completedCtl, false);

    await _ensurePlayer(url);

    final handle = _handle!;
    try {
      await CustomExoPlayer.setMediaItem(handle.playerId, url);
      await CustomExoPlayer.prepare(handle.playerId);
    } catch (e) {
      DiaryService.add('[ExoPlayer] open($url) err: $e');
      rethrow;
    }

    if (startAt != null && startAt > Duration.zero) {
      try {
        await CustomExoPlayer.seekTo(handle.playerId, startAt.inMilliseconds);
        _position = startAt;
        _lastPositionMs = startAt.inMilliseconds;
        _safeAdd(_positionCtl, _position);
      } catch (e) {
        DiaryService.add('[ExoPlayer] initial seekTo($startAt) err: $e');
      }
    }

    try {
      await CustomExoPlayer.play(handle.playerId);
    } catch (e) {
      DiaryService.add('[ExoPlayer] play err: $e');
    }
  }

  @override
  Future<void> play() async {
    final h = _handle;
    if (h == null) return;
    try {
      await CustomExoPlayer.play(h.playerId);
    } catch (_) {}
  }

  @override
  Future<void> pause() async {
    final h = _handle;
    if (h == null) return;
    try {
      await CustomExoPlayer.pause(h.playerId);
    } catch (_) {}
  }

  @override
  Future<void> stop() async {
    final h = _handle;
    if (h == null) return;
    try {
      await CustomExoPlayer.pause(h.playerId);
    } catch (_) {}
    try {
      await CustomExoPlayer.seekTo(h.playerId, 0);
    } catch (_) {}
    _isPlaying = false;
    _isBuffering = false;
    _isCompleted = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _lastPositionMs = 0;
    _safeAdd(_playingCtl, false);
    _safeAdd(_bufferingCtl, false);
    _safeAdd(_completedCtl, false);
    _safeAdd(_positionCtl, _position);
    _safeAdd(_durationCtl, _duration);
  }

  @override
  Future<void> seek(Duration position) async {
    final h = _handle;
    if (h == null) return;
    final ms = position.inMilliseconds;
    try {
      await CustomExoPlayer.seekTo(h.playerId, ms);
    } catch (e) {
      DiaryService.add('[ExoPlayer] seekTo($position) err: $e');
    }
    _position = position;
    _lastPositionMs = ms;
    _safeAdd(_positionCtl, position);
    if (_isCompleted) {
      _isCompleted = false;
      _safeAdd(_completedCtl, false);
    }
  }

  @override
  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    final h = _handle;
    if (h == null) {
      _volume = v;
      return;
    }
    try {
      await CustomExoPlayer.setVolume(h.playerId, v);
    } catch (_) {}
    _volume = v;
  }

  @override
  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.25, 4.0);
    final h = _handle;
    if (h == null) {
      _speed = s;
      return;
    }
    try {
      await CustomExoPlayer.setSpeed(h.playerId, s);
    } catch (e) {
      DiaryService.add('[ExoPlayer] setSpeed($s) err: $e');
    }
    _speed = s;
  }

  @override
  List<MediaTrackInfo> get audioTracks => const [];
  @override
  List<MediaTrackInfo> get subtitleTracks => const [];
  @override
  Future<void> selectAudioTrack(String id) async {}
  @override
  Future<void> selectSubtitleTrack(String id) async {}
  @override
  Future<void> setSubtitleTrackEnabled(bool enabled) async {}

  @override
  Future<void> dispose() async {
    _disposed = true;
    _positionTimer?.cancel();
    _positionTimer = null;
    await _eventSub?.cancel();
    _eventSub = null;
    final h = _handle;
    if (h != null) {
      try {
        await CustomExoPlayer.release(h.playerId);
      } catch (_) {}
      _handle = null;
    }
    await _playingCtl.close();
    await _bufferingCtl.close();
    await _completedCtl.close();
    await _positionCtl.close();
    await _durationCtl.close();
    await _bandwidthCtl.close();
  }

  // ── 辅助 ──────────────────────────────────────────────
  /// v2.3.11: 给 widget 层用, 拿到底层 Flutter SurfaceTexture textureId
  ///   渲染 [Texture] widget. 没初始化完 (player 还没 create) → null,
  ///   widget 渲染黑屏兜底.
  int? get textureId => _handle?.textureId;

  void _safeAdd<T>(StreamController<T> ctl, T value) {
    if (!ctl.isClosed) ctl.add(value);
  }
}
