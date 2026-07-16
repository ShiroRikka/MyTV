// v2.2.0: ExoPlayer (AndroidX Media3) 版本的 [PlayerBackend] 实现.
//
// 走 Flutter 官方 video_player 包 (^2.11.1) — Android 端底层就是 Media3
// ExoPlayer 1.4.x, 跟 build.gradle.kts 里的 androidx.media3 1.4.1 是同一份.
// Dart 端 video_player 不直接暴露 ExoPlayer 实例, 只暴露 VideoPlayerController
// 抽象 API. 优选 IP 走代理 URL (跟 libmpv 时代一样):
//   http://127.0.0.1:PORT/m3u8?url=<原URL>
// ExoPlayer 直接拉这个 URL, 代理服务转发到 CF Worker 加速 + 优选 IP,
// 跟 libmpv 走的是同一条链路.
//
// libmpv 时代 MpvFFI.applyPlaybackTuning 调 hwdec/cache/framedrop 等 mpv
// 配置, ExoPlayer (Media3) 默认就是:
//   - 硬解 (MediaCodec, 不需要手动 hwdec=)
//   - 自适应 buffer (DefaultLoadControl, 不需要 cache=yes)
//   - 丢帧策略 (Media3 默认就是 frame-accurate + adaptive, 不需要 framedrop=vo)
//
// 带宽流: Dart 端 video_player 不暴露 ExoPlayer Listener.onBandwidthSample,
// 带宽走 1s 轮询代理服务 (VideoProxyStatus.fetchedBytes 已经记录). 后端这
// 里带宽流先推空 (UI 不直接消费, cf_acceleration_page 那边自己 poll 代理).
//
// iOS 端走 AVPlayer (video_player 内部), 跟 libmpv 时代一样用, 保持兼容.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:video_player/video_player.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/player_backend.dart';

class ExoPlayerBackend implements PlayerBackend {
  // ── 内部 video_player controller ────────────────────────
  VideoPlayerController? _controller;
  Uri? _proxyBaseUri; // 视频代理基址 (http://127.0.0.1:PORT)

  // ── 缓存的状态 (从 controller.value 同步读) ────────────
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
  VoidCallback? _listener;
  bool _disposed = false;

  ExoPlayerBackend();

  /// v2.2.0: 工厂 — 装配 video_player controller.
  ///   必须在 initState 里 await 调用, 不能在构造同步跑.
  static Future<ExoPlayerBackend> create({
    Uri? httpProxyUri,
    Map<String, String>? defaultHeaders,
  }) async {
    final backend = ExoPlayerBackend();
    backend._proxyBaseUri = httpProxyUri;
    DiaryService.add(
        '[ExoPlayer] init OK: proxy=${httpProxyUri ?? "none"}, headers=${defaultHeaders?.keys.join(",") ?? "none"}');
    return backend;
  }

  /// v2.2.0: 准备 controller, 给定最终 URL. 每次 open() 内部调用.
  Future<void> _ensureController(String url,
      {Map<String, String>? headers}) async {
    if (_disposed) {
      throw StateError('ExoPlayerBackend disposed');
    }
    final old = _controller;
    if (old != null) {
      try {
        if (_listener != null) {
          old.removeListener(_listener!);
        }
      } catch (_) {}
      try {
        await old.dispose();
      } catch (_) {}
      _controller = null;
      _listener = null;
    }

    final c = VideoPlayerController.networkUrl(
      Uri.parse(url),
      videoPlayerOptions: VideoPlayerOptions(mixWithOthers: true),
    );
    _listener = () => _onControllerChanged();
    c.addListener(_listener!);
    await c.initialize();
    _controller = c;
    _syncFromController();
  }

  /// v2.2.0: 监听 video_player controller 变化, 推到 broadcast stream.
  void _onControllerChanged() {
    if (_disposed) return;
    final c = _controller;
    if (c == null) return;
    _syncFromController();
  }

  /// v2.2.0: 把 controller.value 同步到内部字段 (Stream 推完即更新).
  /// 一次性同步所有字段, 避免多 listener 触发多次 setState.
  void _syncFromController() {
    final c = _controller;
    if (c == null) return;
    final v = c.value;
    final isPlaying = v.isPlaying;
    final isBuffering = v.isBuffering;
    final pos = v.position;
    final dur = v.duration;
    final w = v.size.width.isFinite ? v.size.width.toInt() : 0;
    final h = v.size.height.isFinite ? v.size.height.toInt() : 0;
    final speed = v.playbackSpeed;
    // v2.2.0: completed 走 position == duration && duration > 0 推断
    //   video_player 没有显式 completed 字段.
    final completed = dur > Duration.zero && pos >= dur - const Duration(milliseconds: 500);

    if (isPlaying != _isPlaying) {
      _isPlaying = isPlaying;
      _safeAdd(_playingCtl, isPlaying);
    }
    if (isBuffering != _isBuffering) {
      _isBuffering = isBuffering;
      _safeAdd(_bufferingCtl, isBuffering);
    }
    if (dur != _duration && dur > Duration.zero) {
      _duration = dur;
      _safeAdd(_durationCtl, dur);
    }
    if (pos != _position) {
      _position = pos;
      _safeAdd(_positionCtl, pos);
    }
    if (w != _width || h != _height) {
      _width = w;
      _height = h;
    }
    if (speed != _speed) {
      _speed = speed;
    }
    if (completed != _isCompleted) {
      _isCompleted = completed;
      _safeAdd(_completedCtl, completed);
    }

    if (v.hasError && v.errorDescription != null) {
      DiaryService.add('[ExoPlayer] ERROR: ${v.errorDescription}');
      if (!_isCompleted) {
        _isCompleted = true;
        _safeAdd(_completedCtl, true);
      }
    }
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

    // v2.2.0: video_player 不直接传 headers. headers 走代理层注入 (CfOptimizer
    //   装的 HTTP override). 视频代理 URL 优先, 没代理才走原始 URL.
    // 旧 libmpv 时代也是这个套路: buildProxiedUrl 拿到最终 URL, 一次 open.
    // 复用上游已经 buildProxiedUrl 处理好的 URL, 这里只接收.
    await _ensureController(url, headers: headers);

    if (startAt != null && startAt > Duration.zero) {
      try {
        await _controller!.seekTo(startAt);
      } catch (e) {
        DiaryService.add('[ExoPlayer] initial seekTo($startAt) err: $e');
      }
    }
    _position = startAt ?? Duration.zero;
    _safeAdd(_positionCtl, _position);

    try {
      await _controller!.play();
    } catch (e) {
      DiaryService.add('[ExoPlayer] play err: $e');
    }
  }

  @override
  Future<void> play() async {
    await _controller?.play();
  }

  @override
  Future<void> pause() async {
    await _controller?.pause();
  }

  @override
  Future<void> stop() async {
    // v2.2.0: 停播放但保留 controller — 下一集可以重新 open.
    // video_player 没有显式 stop, 用 pause + seek(0) 组合.
    final c = _controller;
    if (c == null) return;
    try {
      await c.pause();
    } catch (_) {}
    try {
      await c.seekTo(Duration.zero);
    } catch (_) {}
    _isPlaying = false;
    _isBuffering = false;
    _isCompleted = false;
    _position = Duration.zero;
    _duration = Duration.zero;
    _safeAdd(_playingCtl, false);
    _safeAdd(_bufferingCtl, false);
    _safeAdd(_completedCtl, false);
    _safeAdd(_positionCtl, _position);
    _safeAdd(_durationCtl, _duration);
  }

  @override
  Future<void> seek(Duration position) async {
    final c = _controller;
    if (c == null) return;
    try {
      await c.seekTo(position);
    } catch (e) {
      DiaryService.add('[ExoPlayer] seekTo($position) err: $e');
    }
    _position = position;
    _safeAdd(_positionCtl, position);
  }

  @override
  Future<void> setVolume(double volume) async {
    final v = volume.clamp(0.0, 1.0);
    final c = _controller;
    if (c == null) return;
    try {
      // v2.2.0: video_player 2.4+ 才有 setVolume. 老版本 setVolume 不存在
      //   走 Dart:io AudioPlayer 那种 — 暂用 try-catch, 不支持就忽略
      //   (音量走 VolumeController.system 已经覆盖系统音量).
      // ignore: invalid_use_of_visible_for_testing_member
      await c.setVolume(v);
    } catch (_) {
      // 兼容老版本 video_player, 静默忽略
    }
    _volume = v;
  }

  @override
  Future<void> setSpeed(double speed) async {
    final s = speed.clamp(0.25, 4.0);
    final c = _controller;
    if (c == null) return;
    try {
      await c.setPlaybackSpeed(s);
    } catch (e) {
      DiaryService.add('[ExoPlayer] setPlaybackSpeed($s) err: $e');
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
    final c = _controller;
    if (c != null) {
      try {
        if (_listener != null) {
          c.removeListener(_listener!);
        }
      } catch (_) {}
      try {
        await c.dispose();
      } catch (_) {}
    }
    _controller = null;
    _listener = null;
    await _playingCtl.close();
    await _bufferingCtl.close();
    await _completedCtl.close();
    await _positionCtl.close();
    await _durationCtl.close();
    await _bandwidthCtl.close();
  }

  // ── 辅助 ──────────────────────────────────────────────
  /// v2.2.0: 给 widget 层用, 拿到底层 VideoPlayerController 渲染 VideoPlayer.
  VideoPlayerController? get rawController => _controller;

  void _safeAdd<T>(StreamController<T> ctl, T value) {
    if (!ctl.isClosed) ctl.add(value);
  }
}
