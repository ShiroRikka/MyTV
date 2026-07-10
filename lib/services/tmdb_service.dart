// v2.0.36: TMDB (The Movie Database) API client
//
// 核心: 通过 CF Worker CORSAPI 加速 TMDB 请求
//   原始: https://api.themoviedb.org/3/movie/popular?api_key=xxx
//   加速: https://{cf-worker}/?url=https%3A%2F%2Fapi.themoviedb.org%2F3%2Fmovie%2Fpopular%3Fapi_key%3Dxxx
//
// 为什么需要加速: TMDB 国内/某些地区访问慢, 走 CF Worker 代理后:
//   - 你设备 -> CF edge (快)
//   - CF edge -> TMDB origin (快, 走 CF 骨干网)
//   - 整条链路在国内/海外都比直连 api.themoviedb.org 快
//
// 配置要求 (v2.0.35 配):
//   1. 设置页 → 海报墙 → TMDB API Key (v3 auth, 免费)
//   2. 设置页 → 加速 → CF Worker 域名 + 开关
// 任一缺失 → 走 fallback:
//   - 无 key → TmdbException(NO_KEY)
//   - 无 CF Worker 域名 → _wrap 直接返回原 URL (走直连, 慢但能用)
//
// 缓存: 1 天本地缓存, 跟 TMDB 自己数据更新周期匹配
//   - SharedPreferences 存 JSON, key = tmdb_cache_{path}_{params_hash}
//   - 内存二级缓存避免每次都读 prefs
//
// 设计参考:
//   - 跟 CfOptimizerHttpOverrides 一样的全局静态方法模式
//   - 走 Dart HttpClient, 触发 CfOptimizerHttpOverrides 全局 hook,
//     HTTP 请求也走优选 IP (跟 v2.0.31 手动优选 IP 字段联动)

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/cf_optimizer.dart' show CfOptimizerHttpOverrides;
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/video_proxy_log.dart';

/// v2.0.36: TMDB API 异常
class TmdbException implements Exception {
  final String message;
  final String code; // NO_KEY / INVALID_KEY / NETWORK / HTTP_xxx
  final int? httpStatus;

  const TmdbException(this.message,
      {required this.code, this.httpStatus});

  @override
  String toString() => 'TmdbException($code): $message';

  /// 翻译成中文给用户看
  String toUserMessage() {
    switch (code) {
      case 'NO_KEY':
        return '未配置 TMDB API Key. 去 设置 → 海报墙 申请并填入.';
      case 'INVALID_KEY':
        return 'TMDB API Key 无效 (401). 重新去 themoviedb.org/settings/api 复制.';
      case 'NETWORK':
        return '网络异常: $message. 检查网络 / CF Worker 域名是否配对.';
      default:
        if (httpStatus != null) {
          return 'TMDB 错误 $httpStatus: $message';
        }
        return message;
    }
  }
}

/// v2.0.36: 媒体类型
enum TmdbMediaType {
  movie('movie'),
  tv('tv'),
  person('person');

  final String value;
  const TmdbMediaType(this.value);

  static TmdbMediaType fromString(String s) {
    for (final t in TmdbMediaType.values) {
      if (t.value == s) return t;
    }
    return TmdbMediaType.movie;
  }
}

/// v2.0.36: trending 时间窗
enum TmdbTimeWindow {
  day('day'),
  week('week');

  final String value;
  const TmdbTimeWindow(this.value);
}

/// v2.0.36: 一个 TMDB 媒体条目 (movie 或 tv)
class TmdbItem {
  final int id;
  final TmdbMediaType mediaType;
  final String title; // movie: title, tv: name
  final String originalTitle;
  final String? posterPath;
  final String? backdropPath;
  final String overview;
  final double voteAverage; // 0-10
  final int voteCount;
  final String? releaseDate; // movie: release_date, tv: first_air_date
  final List<int> genreIds;

  const TmdbItem({
    required this.id,
    required this.mediaType,
    required this.title,
    required this.originalTitle,
    required this.posterPath,
    required this.backdropPath,
    required this.overview,
    required this.voteAverage,
    required this.voteCount,
    required this.releaseDate,
    required this.genreIds,
  });

  /// 从 TMDB JSON 解析. 兼容 movie / tv / trending 混合响应.
  factory TmdbItem.fromJson(Map<String, dynamic> json) {
    final type = json['media_type'] != null
        ? TmdbMediaType.fromString(json['media_type'] as String)
        : (json['title'] != null
            ? TmdbMediaType.movie
            : TmdbMediaType.tv);
    final title = (type == TmdbMediaType.movie
            ? json['title']
            : json['name']) as String? ??
        '';
    final original = (type == TmdbMediaType.movie
            ? json['original_title']
            : json['original_name']) as String? ??
        '';
    final date = (type == TmdbMediaType.movie
            ? json['release_date']
            : json['first_air_date']) as String?;
    final genres = (json['genre_ids'] as List?)
            ?.map((e) => (e as num).toInt())
            .toList() ??
        const [];
    final vote = (json['vote_average'] as num?)?.toDouble() ?? 0;
    final votes = (json['vote_count'] as num?)?.toInt() ?? 0;

    return TmdbItem(
      id: (json['id'] as num).toInt(),
      mediaType: type,
      title: title,
      originalTitle: original,
      posterPath: json['poster_path'] as String?,
      backdropPath: json['backdrop_path'] as String?,
      overview: (json['overview'] as String?) ?? '',
      voteAverage: vote,
      voteCount: votes,
      releaseDate: date,
      genreIds: genres,
    );
  }

  /// 年份 (从 release_date 截前 4 字符)
  int? get year {
    if (releaseDate == null || releaseDate!.length < 4) return null;
    return int.tryParse(releaseDate!.substring(0, 4));
  }

  /// 评分百分比 (0-100)
  int get votePercent => (voteAverage * 10).round();
}

/// v2.0.36: 分页结果
class TmdbPagedResult<T> {
  final int page;
  final List<T> results;
  final int totalPages;
  final int totalResults;

  const TmdbPagedResult({
    required this.page,
    required this.results,
    required this.totalPages,
    required this.totalResults,
  });

  factory TmdbPagedResult.fromJson(Map<String, dynamic> json,
      T Function(Map<String, dynamic>) parseItem) {
    final results = (json['results'] as List?)
            ?.map((e) => parseItem(e as Map<String, dynamic>))
            .toList() ??
        const [];
    return TmdbPagedResult(
      page: (json['page'] as num?)?.toInt() ?? 1,
      results: results,
      totalPages: (json['total_pages'] as num?)?.toInt() ?? 0,
      totalResults: (json['total_results'] as num?)?.toInt() ?? 0,
    );
  }
}

/// v2.0.36: TMDB 配置 (含图片 CDN base url)
class TmdbConfiguration {
  final String imageBaseUrl; // e.g. https://image.tmdb.org/t/p/
  final List<String> posterSizes;
  final List<String> backdropSizes;

  const TmdbConfiguration({
    required this.imageBaseUrl,
    required this.posterSizes,
    required this.backdropSizes,
  });

  /// 海报图完整 URL
  ///   size: 'w92' / 'w154' / 'w185' / 'w342' / 'w500' / 'w780' / 'original'
  String posterUrl(String? path, {String size = 'w500'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBaseUrl$size$path';
  }

  String backdropUrl(String? path, {String size = 'w1280'}) {
    if (path == null || path.isEmpty) return '';
    return '$imageBaseUrl$size$path';
  }

  factory TmdbConfiguration.fromJson(Map<String, dynamic> json) {
    final images = json['images'] as Map<String, dynamic>?;
    final baseUrl = (images?['secure_base_url'] as String?) ??
        (images?['base_url'] as String?) ??
        'https://image.tmdb.org/t/p/';
    final poster = (images?['poster_sizes'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const ['w185', 'w500', 'original'];
    final backdrop = (images?['backdrop_sizes'] as List?)
            ?.map((e) => e.toString())
            .toList() ??
        const ['w1280', 'original'];
    return TmdbConfiguration(
      imageBaseUrl: baseUrl,
      posterSizes: poster,
      backdropSizes: backdrop,
    );
  }
}

/// v2.0.36: 缓存条目
class _CacheEntry {
  final DateTime savedAt;
  final dynamic data;
  const _CacheEntry(this.savedAt, this.data);
}

class TmdbService {
  TmdbService._();

  static const String _baseUrl = 'https://api.themoviedb.org/3';
  // v2.0.45: 改成中文资源. TMDB 支持 language 参数指定返回字段的语言,
  //   zh-CN 返回简体中文标题/简介; region=CN 让海报/人气榜单偏向国内观众.
  //   之前没传 → 英文标题 + 英文 overview, 跟"海报墙"墙不匹配.
  static const String _language = 'zh-CN';
  static const String _region = 'CN';
  static const Duration _cacheTtl = Duration(days: 1);
  // TMDB free API: 40 req/10s, 1 天缓存命中率应该 90%+, 压力很小

  // 内存缓存 (path + params 序列化 -> entry)
  static final Map<String, _CacheEntry> _memoryCache = {};

  // ===== 公共 API =====

  /// v2.0.36: 拿 TMDB 配置 (含图片 CDN base url)
  ///
  /// 这个调用频次很低 (App 启动一次, 或 key 变了一次), 1 天缓存
  static Future<TmdbConfiguration> getConfiguration() async {
    final json = await _httpGet('/configuration',
        {'language': _language}, useCache: true);
    return TmdbConfiguration.fromJson(json as Map<String, dynamic>);
  }

  /// v2.0.36: 热门 (按 type 分)
  ///
  /// [type] 限定 movie 或 tv, person 不接
  /// [page] 默认 1
  static Future<TmdbPagedResult<TmdbItem>> getPopular({
    required TmdbMediaType type,
    int page = 1,
  }) async {
    assert(type == TmdbMediaType.movie || type == TmdbMediaType.tv,
        'getPopular only supports movie/tv');
    final json = await _httpGet(
      '/${type.value}/popular',
      {
        'page': '$page',
        'language': _language,
        'region': _region,
      },
      useCache: true,
    );
    return TmdbPagedResult.fromJson(
        json as Map<String, dynamic>, TmdbItem.fromJson);
  }

  /// v2.0.36: 趋势 (今日/本周), 不分 movie/tv 混合返回
  static Future<TmdbPagedResult<TmdbItem>> getTrending({
    required TmdbMediaType type,
    TmdbTimeWindow window = TmdbTimeWindow.day,
    int page = 1,
  }) async {
    final json = await _httpGet(
      '/trending/${type.value}/${window.value}',
      {
        'page': '$page',
        'language': _language,
      },
      useCache: true,
    );
    return TmdbPagedResult.fromJson(
        json as Map<String, dynamic>, TmdbItem.fromJson);
  }

  /// v2.0.36: 搜剧 (剧名 + 年份可选)
  static Future<TmdbPagedResult<TmdbItem>> search({
    required TmdbMediaType type,
    required String query,
    int? year,
    int page = 1,
  }) async {
    final params = <String, String>{
      'query': query,
      'page': '$page',
      'language': _language,
    };
    if (year != null) {
      params[type == TmdbMediaType.movie ? 'year' : 'first_air_date_year'] =
          '$year';
    }
    final json = await _httpGet(
      '/search/${type.value}',
      params,
      useCache: true,
    );
    return TmdbPagedResult.fromJson(
        json as Map<String, dynamic>, TmdbItem.fromJson);
  }

  /// v2.0.36: 详情 (movie 或 tv)
  static Future<TmdbItem?> getDetails({
    required TmdbMediaType type,
    required int id,
  }) async {
    try {
      final json = await _httpGet(
        '/${type.value}/$id',
        {'language': _language},
        useCache: true,
      );
      // 详情返回不带 media_type, 根据 type 字段缺失推断
      final map = json as Map<String, dynamic>;
      map['media_type'] ??= type.value;
      return TmdbItem.fromJson(map);
    } on TmdbException catch (e) {
      if (e.httpStatus == 404) return null;
      rethrow;
    }
  }

  /// v2.0.36: 清缓存 (测试用, 或用户主动重置)
  static Future<void> clearCache() async {
    _memoryCache.clear();
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs.getKeys().where((k) => k.startsWith('tmdb_cache_'));
    for (final k in keys) {
      await prefs.remove(k);
    }
  }

  // ===== 内部 =====

  /// v2.0.45: 拼 URL + 走 CORSAPI 包装
  ///
  ///   tmdb_url -> https://{cf-worker}/?url={encoded(tmdb_url)}
  ///   如果 CF Worker 不可用 (没配域名 / 用户选直连) -> 返回原 URL (直连)
  ///
  /// 跟 [UserDataService.buildProxiedUrlAsync] 不同: 多了"用户选的 TMDB 数据源"
  /// 判断 — 用户选"直连"时强制走原 URL, 选"CF Worker 加速"时走 buildProxiedUrl.
  /// 跟豆瓣/Bangumi 的数据源选择器对齐 (v2.0.45).
  static Future<String> _wrap(String tmdbUrl) async {
    // v2.0.45: 走 UserDataService.buildTmdbDataUrl (同步)
    //   - 用户选"直连" → 原 URL
    //   - 用户选"CF Worker 加速" + 域名配了 → 走 worker
    //   - 用户选"CF Worker 加速" + 域名没配 → 退化成直连
    // buildTmdbDataUrl 内部读 _tmdbDataSourceCache (warmupCfWorkerConfig 时初始化),
    //   这里 await 一次保证 cache 已就绪.
    await UserDataService.getTmdbDataSourceKey();
    return UserDataService.buildTmdbDataUrl(tmdbUrl);
  }

  /// v2.0.36: HTTP GET + 1 天本地缓存
  ///
  /// useCache: false 用于调试 (强制走网络)
  /// v2.0.55: 加 [TMDB] 日记, 玩家屏幕"日记"按钮能看 — 用户反馈
  ///   "tmdb 获取有问题, 只有历史里面能获取海报", 没法判断是 cache miss
  ///   / 网络 / CF Worker / TMDB rate limit. 详细日记能看清:
  ///   缓存命中? 走的 CF Worker 还是直连? HTTP 状态码? body? 异常?
  static Future<dynamic> _httpGet(
    String path,
    Map<String, String> params, {
    bool useCache = true,
  }) async {
    final key = await UserDataService.getTmdbApiKey();
    if (key == null || key.isEmpty) {
      // ignore: avoid_print
      VideoProxyLog.append('[TMDB] 未配置 API Key — 去设置填');
      throw const TmdbException('未配置 TMDB API Key', code: 'NO_KEY');
    }

    // 拼 query string, 保留原始顺序方便缓存命中
    final orderedParams = <String, String>{'api_key': key, ...params};
    final qs = orderedParams.entries
        .map((e) => '${e.key}=${Uri.encodeQueryComponent(e.value)}')
        .join('&');
    final cacheKey = useCache ? _cacheKey(path, qs) : null;
    // ignore: avoid_print
    VideoProxyLog.append('[TMDB] 准备 GET $path (cacheKey=$cacheKey)');

    // 1) 内存缓存
    if (cacheKey != null) {
      final mem = _memoryCache[cacheKey];
      if (mem != null &&
          DateTime.now().difference(mem.savedAt) < _cacheTtl) {
        final ageMin = DateTime.now().difference(mem.savedAt).inMinutes;
        // ignore: avoid_print
        VideoProxyLog.append('[TMDB] 命中内存缓存 (${ageMin} 分钟前存)');
        return mem.data;
      }
    }
    // 2) SharedPreferences 缓存
    if (cacheKey != null) {
      final cached = await _readFromPrefs(cacheKey);
      if (cached != null) {
        // ignore: avoid_print
        VideoProxyLog.append('[TMDB] 命中 SharedPreferences 缓存');
        // 写回内存缓存
        _memoryCache[cacheKey] = _CacheEntry(DateTime.now(), cached);
        return cached;
      }
    }
    // ignore: avoid_print
    VideoProxyLog.append('[TMDB] 缓存 miss, 准备真发请求');

    // 3) 真发请求
    final tmdbUrl = '$_baseUrl$path?$qs';
    final url = await _wrap(tmdbUrl);
    // ignore: avoid_print
    VideoProxyLog.append(
        '[TMDB] 实际 URL: ${url.substring(0, url.length > 160 ? 160 : url.length)}${url.length > 160 ? "..." : ""}');

    // v2.0.71: 改用 SecureSocket 手动 TLS, 绕开 CfOptimizerHttpOverrides 的 SNI 污染.
    //   跟 v2.0.68 video_proxy_server 同样的修复 — HttpClient 被
    //   CfOptimizerHttpOverrides 全局 hook, URI host 改成优选 IP →
    //   TLS SNI = IP → CF edge 拒绝握手 (HandshakeException).
    //   TMDB 走 CF Worker 时也中招 (12:19 日记: TLS 握手异常).
    //   修法: 走 worker 时手动 Socket.connect(ip,443) + SecureSocket.secure(host:domain),
    //         直连 api.themoviedb.org 时仍用 HttpClient (没 hook 污染).
    final parsed = Uri.parse(url);
    final isWorkerProxy = parsed.host != 'api.themoviedb.org';
    final String statusLine;
    final Map<String, String> respHeaders;
    final String body;
    if (isWorkerProxy) {
      // 走 CF Worker: 手动 TLS, SNI = worker host (不被优选 IP 污染)
      final result = await _httpGetViaSecureSocket(parsed);
      statusLine = result.$1;
      respHeaders = result.$2;
      body = result.$3;
    } else {
      // 直连 api.themoviedb.org: 用 HttpClient (没 hook, 原始域名)
      final result = await _httpGetViaHttpClient(url);
      statusLine = result.$1;
      respHeaders = result.$2;
      body = result.$3;
    }
    final status = int.tryParse(statusLine.split(' ').elementAtOrNull(1) ?? '') ?? 0;
    final ct = respHeaders['content-type'] ?? '?';
    // ignore: avoid_print
    VideoProxyLog.append('[TMDB] 响应 HTTP $status content-type=$ct');

    if (status == 401) {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[TMDB] 401 鉴权失败 — API Key 无效或被 TMDB 撤销, 去 themoviedb.org/settings/api 重新复制');
      throw const TmdbException(
        'TMDB API Key 无效 (401). 去 themoviedb.org/settings/api 重新复制.',
        code: 'INVALID_KEY',
        httpStatus: 401,
      );
    }
    if (status == 404) {
      // ignore: avoid_print
      VideoProxyLog.append('[TMDB] 404 资源不存在');
      throw const TmdbException(
        'TMDB 资源不存在 (404)',
        code: 'HTTP_404',
        httpStatus: 404,
      );
    }
    if (status == 429) {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[TMDB] 429 rate limit — TMDB 限流 40 req/10s, 等会儿再试或减并发');
      throw const TmdbException(
        'TMDB 限流 (429). 40 req/10s, 等 10 秒再试.',
        code: 'RATE_LIMIT',
        httpStatus: 429,
      );
    }
    if (status >= 400) {
      // ignore: avoid_print
      VideoProxyLog.append(
          '[TMDB] HTTP $status 错误, body 前 200: ${body.substring(0, body.length > 200 ? 200 : body.length)}');
      throw TmdbException(
        'TMDB HTTP $status: ${body.substring(0, body.length > 200 ? 200 : body.length)}',
        code: 'HTTP_$status',
        httpStatus: status,
      );
    }
    // ignore: avoid_print
    VideoProxyLog.append(
        '[TMDB] 响应 body ${body.length} bytes, 前 120: ${body.length > 120 ? body.substring(0, 120) + "..." : body}');

    final dynamic json = jsonDecode(body);

    // 写缓存
    if (cacheKey != null) {
      _memoryCache[cacheKey] = _CacheEntry(DateTime.now(), json);
      await _saveToPrefs(cacheKey, json);
      // ignore: avoid_print
      VideoProxyLog.append('[TMDB] 写入缓存 (1 天 TTL)');
    }
    return json;
  }

  /// v2.0.71: 走 CF Worker 时手动 TLS 发请求.
  /// 绕开 CfOptimizerHttpOverrides (它 hook HttpClient 把 host 改成优选 IP,
  /// 导致 SNI = IP → TLS 握手失败).
  ///
  /// 返回 (statusLine, headers, body).
  static Future<(String, Map<String, String>, String)> _httpGetViaSecureSocket(
      Uri uri) async {
    final host = uri.host;
    final port = uri.port == 0 ? 443 : uri.port;
    final pathQuery = uri.path.isEmpty
        ? '/${uri.query.isEmpty ? "" : "?${uri.query}"}'
        : (uri.query.isEmpty ? uri.path : '${uri.path}?${uri.query}');
    final preferIp =
        await UserDataService.getVideoProxyEnabled().then((_) =>
            CfOptimizerHttpOverrides.getResolvedManualIp());

    late SecureSocket upstream;
    try {
      if (preferIp != null && preferIp.isNotEmpty) {
        // 优选 IP: TCP 连优选 IP, TLS SNI = host
        final tcpSocket = await Socket.connect(preferIp, port,
            timeout: const Duration(seconds: 10));
        try {
          tcpSocket.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
        upstream = await SecureSocket.secure(tcpSocket, host: host);
      } else {
        // 系统 DNS: SNI = host 自动
        upstream = await SecureSocket.connect(host, port,
            timeout: const Duration(seconds: 10));
        try {
          upstream.setOption(SocketOption.tcpNoDelay, true);
        } catch (_) {}
      }

      // 发 HTTP/1.1 请求
      final reqBuf = StringBuffer()
        ..write('GET $pathQuery HTTP/1.1\r\n')
        ..write('Host: $host\r\n')
        ..write('Accept: application/json\r\n')
        ..write('User-Agent: LunaTV-Mobile/2.0.71\r\n')
        ..write('Connection: close\r\n')
        ..write('\r\n');
      upstream.add(utf8.encode(reqBuf.toString()));
      await upstream.flush();

      // 读响应
      final reader = _SocketReader(upstream);
      final headerLines = <String>[];
      while (true) {
        final line = await reader.readLine();
        if (line == null) break;
        if (line.isEmpty) break;
        headerLines.add(line);
      }
      if (headerLines.isEmpty) {
        throw TmdbException('upstream 返回空响应', code: 'NETWORK');
      }
      final statusLine = headerLines.first;
      final headers = <String, String>{};
      for (var i = 1; i < headerLines.length; i++) {
        final idx = headerLines[i].indexOf(':');
        if (idx > 0) {
          headers[headerLines[i].substring(0, idx).trim().toLowerCase()] =
              headerLines[i].substring(idx + 1).trim();
        }
      }
      // 读 body (支持 chunked + content-length + 读到 EOF)
      final bodyBytes =
          await reader.readBody(int.tryParse(headers['content-length'] ?? ''),
              (headers['transfer-encoding'] ?? '').toLowerCase().contains('chunked'));
      return (statusLine, headers, utf8.decode(bodyBytes));
    } on SocketException catch (e) {
      VideoProxyLog.append(
          '[TMDB] Socket 异常: ${e.message} (host=${e.address?.host} port=${e.port}) — 检查网络 / CF Worker 域名');
      throw TmdbException('Socket: ${e.message}', code: 'NETWORK');
    } on HandshakeException catch (e) {
      VideoProxyLog.append(
          '[TMDB] TLS 握手异常: ${e.message} — CF Worker 证书错 / 优选 IP 不通');
      throw TmdbException('TLS: ${e.message}', code: 'TLS');
    } on TimeoutException {
      VideoProxyLog.append('[TMDB] 请求超时 (10s) — CF Worker 慢 / 优选 IP 不通');
      throw const TmdbException('请求超时 (10s)', code: 'NETWORK');
    } catch (e) {
      VideoProxyLog.append('[TMDB] 其它异常: $e');
      rethrow;
    } finally {
      try {
        upstream.destroy();
      } catch (_) {}
    }
  }

  /// v2.0.71: 直连 api.themoviedb.org 时用 HttpClient (没 hook 污染).
  static Future<(String, Map<String, String>, String)> _httpGetViaHttpClient(
      String url) async {
    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set('Accept', 'application/json');
      req.headers.set('User-Agent', 'LunaTV-Mobile/2.0.71');
      final resp = await req.close();
      final status = resp.statusCode;
      final ct = resp.headers.value('content-type') ?? '?';
      final body = await resp.transform(utf8.decoder).join();
      final statusLine = 'HTTP/1.1 $status ${resp.reasonPhrase ?? ""}';
      final headers = <String, String>{'content-type': ct};
      resp.headers.forEach((k, v) => headers[k.toLowerCase()] = v.join(','));
      return (statusLine, headers, body);
    } on SocketException catch (e) {
      VideoProxyLog.append(
          '[TMDB] Socket 异常: ${e.message} (host=${e.address?.host} port=${e.port})');
      throw TmdbException('Socket: ${e.message}', code: 'NETWORK');
    } on HandshakeException catch (e) {
      VideoProxyLog.append('[TMDB] TLS 握手异常: ${e.message}');
      throw TmdbException('TLS: ${e.message}', code: 'TLS');
    } on TimeoutException {
      VideoProxyLog.append('[TMDB] 请求超时 (10s)');
      throw const TmdbException('请求超时 (10s)', code: 'NETWORK');
    } catch (e) {
      VideoProxyLog.append('[TMDB] 其它异常: $e');
      rethrow;
    } finally {
      client.close(force: true);
    }
  }

  /// v2.0.36: 缓存 key (path + queryString 的 base64 摘要, 取前 16 字符)
  ///
  /// 不用 crypto 包, 走 dart:convert.base64Url 自带.
  /// 16 字符 base64 足够避免冲突 (1M 缓存 key 碰撞概率 ~10^-7).
  static String _cacheKey(String path, String queryString) {
    final full = '$path?$queryString';
    final b64 = base64Url.encode(utf8.encode(full));
    final digest = b64.length > 16 ? b64.substring(0, 16) : b64;
    return 'tmdb_cache_${path.replaceAll('/', '_')}_$digest';
  }

  /// v2.0.36: 从 SharedPreferences 读缓存
  static Future<dynamic> _readFromPrefs(String key) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(key);
      if (raw == null) return null;
      final map = jsonDecode(raw) as Map<String, dynamic>;
      final ts = (map['ts'] as num?)?.toInt() ?? 0;
      if (DateTime.now().millisecondsSinceEpoch - ts > _cacheTtl.inMilliseconds) {
        // 过期
        await prefs.remove(key);
        return null;
      }
      return map['data'];
    } catch (_) {
      return null;
    }
  }

  /// v2.0.36: 写 SharedPreferences 缓存
  static Future<void> _saveToPrefs(String key, dynamic data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonEncode({
        'ts': DateTime.now().millisecondsSinceEpoch,
        'data': data,
      });
      await prefs.setString(key, raw);
    } catch (_) {
      // 缓存失败无所谓, 反正能 fallback 网络
    }
  }
}

/// v2.0.71: 封装 socket 读取 (跟 video_proxy_server._SocketReader 一样,
/// 但 TMDB 模块自己独立一份, 不跨模块依赖).
class _SocketReader {
  final Socket _socket;
  final List<int> _buf = [];
  bool _eof = false;
  late final StreamIterator<List<int>> _iter;

  _SocketReader(this._socket) : _iter = StreamIterator(_socket);

  Future<String?> readLine() async {
    while (true) {
      // 找 \r\n
      for (var i = 0; i < _buf.length - 1; i++) {
        if (_buf[i] == 0x0D && _buf[i + 1] == 0x0A) {
          final line = utf8.decode(_buf.sublist(0, i));
          _buf.removeRange(0, i + 2);
          return line;
        }
      }
      // 单独的 \n (容错)
      for (var i = 0; i < _buf.length; i++) {
        if (_buf[i] == 0x0A) {
          final line = utf8.decode(_buf.sublist(0, i));
          _buf.removeRange(0, i + 1);
          return line;
        }
      }
      if (_eof) return null;
      final more = await _iter.moveNext();
      if (!more) {
        _eof = true;
        continue;
      }
      _buf.addAll(_iter.current);
    }
  }

  Future<List<int>> readN(int n) async {
    while (_buf.length < n && !_eof) {
      final more = await _iter.moveNext();
      if (!more) {
        _eof = true;
        break;
      }
      _buf.addAll(_iter.current);
    }
    final take = _buf.length < n ? _buf.length : n;
    final out = _buf.sublist(0, take);
    _buf.removeRange(0, take);
    return out;
  }

  Future<List<int>> readBody(int? contentLength, bool isChunked) async {
    if (isChunked) {
      // chunked: 读 size\r\n + data\r\n 直到 size=0
      final body = <int>[];
      while (true) {
        final sizeLine = await readLine();
        if (sizeLine == null) break;
        final sizeStr = sizeLine.split(';').first.trim();
        final size = int.tryParse(sizeStr, radix: 16);
        if (size == null || size == 0) break;
        final chunk = await readN(size);
        body.addAll(chunk);
        await readN(2); // 吃 \r\n
      }
      return body;
    }
    if (contentLength != null && contentLength >= 0) {
      return await readN(contentLength);
    }
    // 读到 EOF
    final body = List<int>.from(_buf);
    _buf.clear();
    while (!_eof) {
      final more = await _iter.moveNext();
      if (!more) {
        _eof = true;
        break;
      }
      body.addAll(_iter.current);
    }
    return body;
  }
}
