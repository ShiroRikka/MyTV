import 'package:flutter/services.dart';

/// v2.3.10: 自定义 ExoPlayer Dart 端 wrapper.
///
/// 跟原生 [CustomExoPlayerChannel.kt] (Kotlin) 对应. 这个 player 用
///   自定义 [DefaultLoadControl]:
///   - minBufferMs: 30s (video_player 默认 15s)
///   - maxBufferMs: 90s (video_player 默认 50s)
///   - bufferForPlaybackMs: 5s (video_player 默认 2.5s)
///   - bufferForPlaybackAfterRebufferMs: 8s (video_player 默认 5s)
///
/// 目的: 卡顿时 (isBuffering 反复 true/false) 给 ExoPlayer 更多时间
///   填 buffer, 减少 rebuffer 频率. 视频加速 (CF Worker 代理) 删了
///   之后, 源站 CDN 直连, 网络抖动比之前更明显, 大 buffer 有明显改善.
///
/// v2.3.10 的使用方式: **不影响现有 video_player 渲染**, 只做 buffer
///   prefetch. 在 [PlayerBackend.open] 时创建 hidden player, prepare()
///   但不 play(), 让 ExoPlayer 内部下载 m3u8 + 选 variant + 填 buffer
///   到 30s. 等 1-2s 后再调 video_player 的 controller.initialize().
///   实际播放的 player 还是 video_player (走 Android 原生 Media3), 但
///   由于下载链路 (同一 OkHttp client / connection pool) 共享, 提前
///   下的 segment 走 OS 网络 cache / OkHttp connection pool 命中,
///   起播和早期播放更顺.
///
/// 跟 [ExoSpeedTestChannel] (v2.3.6 加的, v2.3.9 废弃) 不一样: 那个
///   只测速, 这个真的预下载 + 实际可播放.
class CustomExoPlayer {
  CustomExoPlayer._();

  static const MethodChannel _methodChannel =
      MethodChannel('org.moontechlab.lunatv/custom_exo_player');

  static const EventChannel _eventChannel =
      EventChannel('org.moontechlab.lunatv/custom_exo_player_events');

  static Stream<Map<String, dynamic>>? _eventsStream;

  /// v2.3.10 默认 buffer 配置 (毫秒) — 跟 Kotlin 默认值同步.
  static const int defaultMinBufferMs = 30_000;
  static const int defaultMaxBufferMs = 90_000;
  static const int defaultBufferForPlaybackMs = 5_000;
  static const int defaultBufferForPlaybackAfterRebufferMs = 8_000;

  /// 创建一个自定义 ExoPlayer 实例, 返回 playerId.
  /// 之后所有操作都通过 playerId 关联.
  ///
  /// 默认 buffer 配置用 30s/90s/5s/8s. 如果想自定义可以传 bufferConfig
  ///   参数覆盖.
  static Future<int> create({
    int? minBufferMs,
    int? maxBufferMs,
    int? bufferForPlaybackMs,
    int? bufferForPlaybackAfterRebufferMs,
  }) async {
    final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
      'create',
      <String, dynamic>{
        if (minBufferMs != null) 'minBufferMs': minBufferMs,
        if (maxBufferMs != null) 'maxBufferMs': maxBufferMs,
        if (bufferForPlaybackMs != null) 'bufferForPlaybackMs': bufferForPlaybackMs,
        if (bufferForPlaybackAfterRebufferMs != null)
          'bufferForPlaybackAfterRebufferMs': bufferForPlaybackAfterRebufferMs,
      },
    );
    if (result == null) {
      throw StateError('CustomExoPlayer.create returned null');
    }
    return (result['playerId'] as num).toInt();
  }

  static Future<void> setMediaItem(int playerId, String url) async {
    await _methodChannel.invokeMethod('setMediaItem', <String, dynamic>{
      'playerId': playerId,
      'url': url,
    });
  }

  static Future<void> prepare(int playerId) async {
    await _methodChannel.invokeMethod('prepare', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> play(int playerId) async {
    await _methodChannel.invokeMethod('play', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> pause(int playerId) async {
    await _methodChannel.invokeMethod('pause', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> stop(int playerId) async {
    await _methodChannel.invokeMethod('stop', <String, dynamic>{
      'playerId': playerId,
    });
  }

  static Future<void> seekTo(int playerId, int positionMs) async {
    await _methodChannel.invokeMethod('seekTo', <String, dynamic>{
      'playerId': playerId,
      'positionMs': positionMs,
    });
  }

  static Future<void> setVolume(int playerId, double volume) async {
    await _methodChannel.invokeMethod('setVolume', <String, dynamic>{
      'playerId': playerId,
      'volume': volume,
    });
  }

  static Future<void> setSpeed(int playerId, double speed) async {
    await _methodChannel.invokeMethod('setSpeed', <String, dynamic>{
      'playerId': playerId,
      'speed': speed,
    });
  }

  static Future<CustomExoPlayerState?> getState(int playerId) async {
    try {
      final result = await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
        'getState',
        <String, dynamic>{'playerId': playerId},
      );
      if (result == null) return null;
      return CustomExoPlayerState._fromMap(result);
    } on PlatformException {
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  static Future<void> release(int playerId) async {
    try {
      await _methodChannel.invokeMethod('release', <String, dynamic>{
        'playerId': playerId,
      });
    } on PlatformException catch (_) {}
    on MissingPluginException catch (_) {}
  }

  static Future<void> releaseAll() async {
    try {
      await _methodChannel.invokeMethod('releaseAll');
    } on PlatformException catch (_) {}
    on MissingPluginException catch (_) {}
  }

  /// v2.3.10: 监听所有 player 的状态变化 (broadcast stream).
  /// 状态 map 包含 playerId, isPlaying, isBuffering, durationMs,
  ///   positionMs, playbackState.
  static Stream<Map<String, dynamic>> get events {
    _eventsStream ??= _eventChannel
        .receiveBroadcastStream()
        .map<Map<String, dynamic>>((event) {
      if (event is Map) {
        return event.map((k, v) => MapEntry(k.toString(), v));
      }
      return <String, dynamic>{};
    });
    return _eventsStream!;
  }

  /// v2.3.10: 检查 channel 是否可用 (iOS / 桌面 fallback).
  static Future<bool> isAvailable() async {
    try {
      await _methodChannel.invokeMethod<Map<dynamic, dynamic>>(
        'create',
        <String, dynamic>{},
      );
      // 成功 = channel 已注册. 但这样会泄露一个 player 实例.
      // 实际场景: ExoPlayerBackend 在 init 调一次, 失败就 fallback.
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      // 其他异常 (e.g. INVALID_ARG 等) 也算 channel 已注册
      return true;
    }
  }
}

class CustomExoPlayerState {
  final bool isPlaying;
  final bool isBuffering;
  final int durationMs;
  final int positionMs;
  final int playbackState;
  final String error;

  const CustomExoPlayerState({
    required this.isPlaying,
    required this.isBuffering,
    required this.durationMs,
    required this.positionMs,
    required this.playbackState,
    required this.error,
  });

  factory CustomExoPlayerState._fromMap(Map m) {
    return CustomExoPlayerState(
      isPlaying: m['isPlaying'] == true,
      isBuffering: m['isBuffering'] == true,
      durationMs: (m['durationMs'] as num?)?.toInt() ?? 0,
      positionMs: (m['positionMs'] as num?)?.toInt() ?? 0,
      playbackState: (m['playbackState'] as num?)?.toInt() ?? 0,
      error: (m['error'] as String?) ?? '',
    );
  }
}
