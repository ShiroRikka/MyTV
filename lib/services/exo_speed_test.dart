import 'package:flutter/services.dart';

/// v2.3.6: Dart 端 ExoPlayer 测速 channel wrapper.
///
/// 跟 [android/app/src/main/kotlin/com/example/lunatv/ExoSpeedTestChannel.kt]
/// 对应, 走原生 ExoPlayer (AndroidX Media3) 真实 prepare() m3u8 URL,
/// 监听 `AnalyticsListener.onLoadCompleted` 算第一个非 manifest 分片
/// 的下载速度. 跟 web 版 LunaTV (hls.js FRAG_LOADED) 思路 1:1 对齐.
///
/// 跟之前 v2.3.3-2.3.5 Dart 端 Dio Range 抽样测速的根本区别:
///   - 旧: 解析 m3u8 playlist → 取 segment URL → Dio `Range: bytes=0-1048575`
///     流式读 512KB. CDN 经常对 Range 请求限速 (5KB/s), 而且
///     测速路径跟播放路径可能不一致 (Range 走的是 byte-range 优化路径,
///     播放走的是整段 GET 路径).
///   - 新: 直接让 ExoPlayer (跟实际播放用同一个 player) 准备 m3u8,
///     ExoPlayer 内部走 HlsMediaSource → 真实 segment GET (无 Range),
///     测量的是跟播放 100% 一致的下载速度.
///
/// 失败兜底: 调原生 channel 抛 `MissingPluginException` (e.g. iOS / 桌面)
///   或 `PlatformException` (ExoPlayer 解析失败) 时, [testSpeed] 返回
///   `success=false`. Dart 端 [M3U8Service] 看到这个就降级到原 Dart
///   Range 测速.
class ExoSpeedTest {
  ExoSpeedTest._();

  static const MethodChannel _channel =
      MethodChannel('org.moontechlab.lunatv/exo_speed_test');

  /// 测一个 URL 的下载速度. 内部跑 ExoPlayer, 监听第一个非 manifest
  /// 分片 (>32KB) 的 load 耗时, 算 KB/s.
  ///
  /// - [url] m3u8 / mp4 / 任意 ExoPlayer 支持的 URL
  /// - [timeoutMs] 等待首个分片 load 的最大时间. 默认 5000ms.
  ///   ExoPlayer 内部要先下 manifest (1s 左右) + 选 variant + 下分片
  ///   (1-3s). 5s 大概够大部分源, 慢链可以调到 8s.
  static Future<ExoSpeedTestResult> testSpeed(
    String url, {
    int timeoutMs = 5000,
  }) async {
    if (url.isEmpty) {
      return ExoSpeedTestResult.failure(error: 'empty url');
    }
    try {
      final raw = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'testSpeed',
        <String, dynamic>{
          'url': url,
          'timeoutMs': timeoutMs,
        },
      );
      if (raw == null) {
        return ExoSpeedTestResult.failure(error: 'null result');
      }
      return ExoSpeedTestResult(
        success: raw['success'] == true,
        downloadSpeedKBps: _toDouble(raw['downloadSpeed']),
        latencyMs: _toInt(raw['latencyMs']),
        bytesLoaded: _toInt(raw['bytesLoaded']),
        prepareMs: _toInt(raw['prepareMs']),
        error: raw['error'] as String?,
      );
    } on MissingPluginException catch (e) {
      // iOS / 桌面 / 老的 Android 设备没注册 channel. 走 Dart fallback.
      return ExoSpeedTestResult.failure(error: 'missing plugin: ${e.message}');
    } on PlatformException catch (e) {
      return ExoSpeedTestResult.failure(error: 'platform: ${e.message}');
    } catch (e) {
      return ExoSpeedTestResult.failure(error: e.toString());
    }
  }

  /// 检查 channel 是否已注册 (warmup 检测). 给上层做 feature flag 用.
  /// 不实际跑测速, 只看 channel 在不在.
  static Future<bool> isAvailable() async {
    try {
      // 用一个明显会失败的 URL 试一下, 1s timeout. 只要 channel
      //   收到 call 并返回 result (无论 success/fail), 就说明
      //   channel 已注册.
      await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'testSpeed',
        <String, dynamic>{
          'url': 'https://invalid.invalid/__probe__',
          'timeoutMs': 100,
        },
      );
      return true;
    } on MissingPluginException {
      return false;
    } catch (_) {
      // 任何其他异常 (网络错误 / 超时) 都算 channel 已注册, 只是探测失败
      return true;
    }
  }

  static double _toDouble(dynamic v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v) ?? 0.0;
    return 0.0;
  }

  static int _toInt(dynamic v) {
    if (v is num) return v.toInt();
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }
}

/// v2.3.6: ExoPlayer 测速结果.
class ExoSpeedTestResult {
  /// 测速是否拿到有效数据 (首个分片 load 完成).
  final bool success;

  /// 第一个非 manifest 分片的下载速度, KB/s.
  final double downloadSpeedKBps;

  /// 整个测速耗时 (从调 testSpeed 到首个分片 load 完 / 超时), ms.
  /// 近似 client 到源端 + 首个分片下载的 RTT.
  final int latencyMs;

  /// 实际下载的字节数 (首个 > 32KB 的分片). 0 表示失败 / 超时.
  final int bytesLoaded;

  /// prepare() 到首个 load started 的时间, ms. 比 [latencyMs] 更细,
  /// 反映 "打开页面到首字节" 的真实延迟.
  final int prepareMs;

  /// 错误消息. null 表示成功.
  final String? error;

  const ExoSpeedTestResult({
    required this.success,
    required this.downloadSpeedKBps,
    required this.latencyMs,
    required this.bytesLoaded,
    required this.prepareMs,
    this.error,
  });

  factory ExoSpeedTestResult.failure({String? error}) => ExoSpeedTestResult(
        success: false,
        downloadSpeedKBps: 0.0,
        latencyMs: 0,
        bytesLoaded: 0,
        prepareMs: 0,
        error: error,
      );

  @override
  String toString() => 'ExoSpeedTestResult(success=$success, '
      'speed=${downloadSpeedKBps.toStringAsFixed(1)}KB/s, '
      'latency=${latencyMs}ms, bytes=$bytesLoaded, '
      'prepare=${prepareMs}ms, error=$error)';
}
