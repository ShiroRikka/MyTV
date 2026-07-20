// lib/services/source_browser_service.dart
// v2.3.31: 源浏览器 service
//   4 个方法对应源 API 的 4 个 ac=:
//     ac=list                  → getCategories  取分类列表
//     ac=videolist&t=X&pg=N    → getList        按分类取列表
//     ac=videolist&wd=Q&pg=N   → search         在某源内搜
//     ac=videolist&ids=ID      → getDetail      取详情
//
// v2.4.5: 改用 HttpShared 公共 helper (UA / timeout / buildUrl / decodeBody).
//   v2.4.4 把传输层配置 (Chrome 147 / 15s timeout / _buildUrl) 写死在本文件,
//   导致 downstream_service 和 search_service 仍是 Chrome 122 + 8s + 直接拼 URL.
//   抽到 HttpShared 后 3 个 service 共用, 以后改一处全链路生效.
//   同时修 class 字段 cast 安全 (json['class'] is! List 时返空, 不抛 TypeError).
//
// 5 分钟 in-memory cache (key = `categories:$resourceKey` 等), 源浏览器来回
//   切分类/翻页不重复打源 API. cache 在进程内, 不进 SharedPreferences (源
//   API 可能改分类, 5 分钟 TTL 足够刷新).

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/search_resource.dart';
import '../models/source_browser.dart';
import 'http_shared.dart';

/// 源浏览器 (分页) 列表结果
class SourceBrowserPage {
  final List<SourceBrowserItem> items;
  final SourceBrowserPageMeta meta;

  const SourceBrowserPage({required this.items, required this.meta});
}

class SourceBrowserService {
  // v2.3.31: 5 分钟内存缓存. key 格式: `<endpoint>:<resourceKey>[:<extra>]`.
  //   同一进程内切分类/翻页不重复打源 API. 进程退出自动清.
  static const Duration _cacheTtl = Duration(minutes: 5);
  static final Map<String, _CacheEntry<dynamic>> _cache = {};

  // -------- cache helpers --------

  static T? _getCached<T>(String key) {
    final entry = _cache[key];
    if (entry == null) return null;
    if (DateTime.now().difference(entry.at) > _cacheTtl) {
      _cache.remove(key);
      return null;
    }
    return entry.value as T;
  }

  static void _setCached(String key, dynamic value) {
    _cache[key] = _CacheEntry<dynamic>(value, DateTime.now());
  }

  /// 清空所有缓存 (源 API 改了 / 切账号 / 用户手动刷新时调)
  static void clearCache() => _cache.clear();

  // -------- public API --------

  /// 取源分类 (源 API `?ac=list`)
  /// 返回 List<SourceCategory>, 失败返 null.
  static Future<List<SourceCategory>?> getCategories(
      SearchResource resource) async {
    final key = 'categories:${resource.key}';
    final cached = _getCached<List<SourceCategory>>(key);
    if (cached != null) return cached;

    final url = HttpShared.buildUrl(resource.api, 'ac=list');
    final json = await _getJson(url, timeout: HttpShared.timeoutCategories);
    if (json == null) return null;

    // v2.4.5: class 字段 cast 安全. 某些源返 `class: ""` / `class: "电影,电视剧"`
    // (字符串而非数组), `as List?` 会抛 TypeError, `?? const []` 接不住.
    // 跟 web categories/route.ts:53-54 `Array.isArray(data.class) ? data.class : []` 1:1.
    if (json['class'] is! List) {
      _setCached(key, const <SourceCategory>[]);
      return const <SourceCategory>[];
    }
    final list = (json['class'] as List)
        .whereType<Map<String, dynamic>>()
        .map(SourceCategory.fromJson)
        .where((c) => c.typeId > 0 && c.typeName.isNotEmpty)
        .toList();
    _setCached(key, list);
    return list;
  }

  /// 按分类取列表 (源 API `?ac=videolist&t=X&pg=N`)
  /// 失败返 null, page 从 1 开始.
  static Future<SourceBrowserPage?> getList(
    SearchResource resource, {
    required int typeId,
    required int page,
  }) async {
    final url = HttpShared.buildUrl(resource.api, 'ac=videolist&t=$typeId&pg=$page');
    return _fetchPage(url, 'list:$typeId:$page', timeout: HttpShared.timeoutList);
  }

  /// 搜索 (源 API `?ac=videolist&wd=Q&pg=N`)
  /// 不传 typeId 全源搜; 传 typeId 在某分类下搜.
  static Future<SourceBrowserPage?> search(
    SearchResource resource, {
    required String query,
    int? typeId,
    required int page,
  }) async {
    final encoded = Uri.encodeComponent(query);
    final tParam = typeId != null ? '&t=$typeId' : '';
    final url = HttpShared.buildUrl(
        resource.api, 'ac=videolist&wd=$encoded$tParam&pg=$page');
    return _fetchPage(url, 'search:$query:$typeId:$page',
        timeout: HttpShared.timeoutDefault);
  }

  /// 取详情 (源 API `?ac=videolist&ids=ID`)
  /// 返回 SourceBrowserDetail, 失败返 null.
  /// 跟 web detail API 行为一致, 用 `?ac=videolist&ids=` 而不是 `?ac=detail&ids=`.
  static Future<SourceBrowserDetail?> getDetail(
    SearchResource resource, {
    required String id,
  }) async {
    final url = HttpShared.buildUrl(resource.api, 'ac=videolist&ids=$id');
    final json = await _getJson(url, timeout: HttpShared.timeoutDefault);
    if (json == null) return null;
    if (json['list'] is! List) return null;
    final list = (json['list'] as List).whereType<Map<String, dynamic>>();
    if (list.isEmpty) return null;
    final first = list.first;
    final episodes =
        HttpShared.parseVodPlayUrl((first['vod_play_url'] ?? '').toString())
            .map((e) => SourceBrowserEpisode(name: e.name, url: e.url))
            .toList();
    return SourceBrowserDetail.fromJson(first, episodes);
  }

  // -------- private helpers --------

  static Future<SourceBrowserPage?> _fetchPage(
      String url, String cacheKey,
      {required Duration timeout}) async {
    if (url.isEmpty) return null;
    final key = 'page:$cacheKey';
    final cached = _getCached<SourceBrowserPage>(key);
    if (cached != null) return cached;

    final json = await _getJson(url, timeout: timeout);
    if (json == null) return null;

    if (json['list'] is! List) return null;
    final items = (json['list'] as List)
        .whereType<Map<String, dynamic>>()
        .map(SourceBrowserItem.fromJson)
        .where((it) => it.id.isNotEmpty && it.title.isNotEmpty)
        .toList();
    final meta = SourceBrowserPageMeta(
      page: (json['page'] as num?)?.toInt() ?? 1,
      pageCount: (json['pagecount'] as num?)?.toInt() ?? 1,
      total: (json['total'] as num?)?.toInt() ?? items.length,
      limit: (json['limit'] as num?)?.toInt() ?? 20,
    );
    final page = SourceBrowserPage(items: items, meta: meta);
    _setCached(key, page);
    return page;
  }

  /// GET 拿 JSON, 失败返 null.
  ///   v2.4.5: 改用 HttpShared.jsonHeaders + HttpShared.decodeBody + HttpShared.parseJson.
  static Future<Map<String, dynamic>?> _getJson(String url,
      {required Duration timeout}) async {
    if (url.isEmpty) return null;
    try {
      final response = await http
          .get(Uri.parse(url), headers: HttpShared.jsonHeaders())
          .timeout(timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        if (kDebugMode) {
          debugPrint(
              '[SourceBrowser] HTTP ${response.statusCode} url=$url');
        }
        return null;
      }
      final decoded = HttpShared.parseJson(HttpShared.decodeBody(response));
      if (decoded is Map<String, dynamic>) return decoded;
      return null;
    } on TimeoutException {
      if (kDebugMode) debugPrint('[SourceBrowser] timeout url=$url');
      return null;
    } catch (e) {
      if (kDebugMode) debugPrint('[SourceBrowser] err url=$url e=$e');
      return null;
    }
  }
}

class _CacheEntry<T> {
  final T value;
  final DateTime at;
  _CacheEntry(this.value, this.at);
}
