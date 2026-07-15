import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:luna_tv/models/bangumi.dart';
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/douban_cache_service.dart';

/// Bangumi 数据服务 (函数级缓存, 一天过期)
///
/// v2.1.40 改: 删 CF Worker (CORSAPI 套娃) / ciao-cors 公共代理加速,
///   一律直连 api.bgm.tv. 删了 _fetchBangumi / _secureSocketGet /
///   _BgmSocketReader / dart:io 依赖 / cf_optimizer 引用.
class BangumiService {
  static final DoubanCacheService _cache = DoubanCacheService();
  static bool _initialized = false;

  static Future<void> _initCache() async {
    if (!_initialized) {
      await _cache.init();
      _initialized = true;
    }
  }

  /// 获取当天的新番放送（根据当前星期几）
  static Future<ApiResponse<List<BangumiItem>>> getTodayCalendar(
    BuildContext context,
  ) async {
    final weekday = DateTime.now().weekday; // 1..7
    return getCalendarByWeekday(context, weekday);
  }

  /// 获取指定星期的新番放送
  static Future<ApiResponse<List<BangumiItem>>> getCalendarByWeekday(
    BuildContext context,
    int weekday, // 1..7 (Monday..Sunday)
  ) async {
    await _initCache();

    // 接口级缓存：缓存原始 API 数组，固定键，不含参数
    const cacheKey = 'bangumi_calendar_raw_v1';

    // 先尝试读取原始数组缓存
    try {
      final cachedRaw = await _cache.get<List<dynamic>>(
        cacheKey,
        (raw) => raw as List<dynamic>,
      );
      if (cachedRaw != null && cachedRaw.isNotEmpty) {
        final calendar = cachedRaw
            .map((item) => BangumiCalendarResponse.fromJson(item as Map<String, dynamic>))
            .toList();
        BangumiCalendarResponse? targetDay;
        for (final day in calendar) {
          if (day.weekday.id == weekday) {
            targetDay = day;
            break;
          }
        }
        final items = targetDay?.items ?? <BangumiItem>[];
        return ApiResponse.success(items);
      }
    } catch (_) {}

    // 未命中缓存，请求接口
    // v2.1.40 改: 删 CF Worker / ciao-cors 兜底, 一律直连 api.bgm.tv
    try {
      const apiUrl = 'https://api.bgm.tv/calendar';

      const headers = <String, String>{
        // ⚠️ api.bgm.tv v0 API 强制要求 User-Agent 是
        //    "App/Version (URL)" 格式,否则返 400!
        // 之前 v1.0.25 改成了 Chrome 标准 UA 导致整个
        // CF 代理都拉不到数据,这就是用户反馈"还是不行"的真因
        'User-Agent':
            'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
        'Accept': 'application/json',
        'Referer': 'https://bgm.tv/',
      };

      // v2.1.40: 网络/握手/超时错 retry 1 次 (救国内出口路由抖),
      //   没了 worker / ciao-cors 多级 fallback.
      final http.Response? response = await _httpGetWithRetry(apiUrl, headers);
      if (response == null || response.statusCode != 200) {
        return ApiResponse.error(
          '获取 Bangumi 日历失败: ${response?.statusCode ?? 'no response'}',
          statusCode: response?.statusCode ?? 0,
        );
      }

      final List<dynamic> responseData = json.decode(response.body);

      // 解析所有星期数据
      final List<BangumiCalendarResponse> calendarData = responseData
          .map((item) => BangumiCalendarResponse.fromJson(item as Map<String, dynamic>))
          .toList();

      BangumiCalendarResponse? targetDay;
      for (final day in calendarData) {
        if (day.weekday.id == weekday) {
          targetDay = day;
          break;
        }
      }

      final items = targetDay?.items ?? <BangumiItem>[];

      // 写入接口级缓存：原始数组
      try {
        await _cache.set(
          cacheKey,
          responseData,
          const Duration(days: 1),
        );
      } catch (_) {}

      return ApiResponse.success(items, statusCode: response.statusCode);
    } catch (e) {
      return ApiResponse.error('Bangumi 数据请求异常: ${e.toString()}');
    }
  }

  /// 获取 Bangumi 详情数据
  ///
  /// 参数说明：
  /// - bangumiId: Bangumi ID
  static Future<ApiResponse<BangumiDetails>> getBangumiDetails(
    BuildContext context, {
    required String bangumiId,
  }) async {
    await _initCache();

    // 生成缓存键
    final cacheKey = _cache.generateBangumiDetailsCacheKey(
      bangumiId: bangumiId,
    );

    // 尝试从缓存获取数据
    try {
      final cachedData = await _cache.get<BangumiDetails>(
        cacheKey,
        (raw) {
          if (raw is! Map<String, dynamic>) {
            throw FormatException('Bangumi 缓存数据格式错误: ${raw.runtimeType}');
          }
          return BangumiDetails.fromJson(raw);
        },
      );

      if (cachedData != null) {
        return ApiResponse.success(cachedData);
      }
    } catch (e) {
      // 缓存读取失败，清理可能损坏的缓存，继续执行网络请求
      try {
        // 清理这个特定的缓存项
        await _cache.set(cacheKey, null, Duration.zero);
      } catch (_) {}
    }

    // v2.1.40 改: 删 CF Worker / ciao-cors 兜底, 一律直连
    try {
      final apiUrl = 'https://api.bgm.tv/v0/subjects/$bangumiId';

      const headers = <String, String>{
        // ⚠️ api.bgm.tv v0 API 强制要求 User-Agent 是
        //    "App/Version (URL)" 格式,否则返 400
        'User-Agent':
            'LunaTV-Mobile/1.0 (https://github.com/djsevenx1/LunaTV-Mobile)',
        'Accept': 'application/json',
        'Referer': 'https://bgm.tv/',
      };

      final http.Response? response = await _httpGetWithRetry(apiUrl, headers);
      if (response == null || response.statusCode != 200) {
        return ApiResponse.error(
          '获取 Bangumi 详情数据失败: ${response?.statusCode ?? 'no response'}',
          statusCode: response?.statusCode ?? 0,
        );
      }

      try {
        final Map<String, dynamic> data = json.decode(response.body);
        final details = BangumiDetails.fromJson(data);

        // 缓存成功的结果，缓存时间为24小时
        try {
          await _cache.set(
            cacheKey,
            details.toJson(),
            const Duration(days: 3),
          );
        } catch (cacheError) {
          // 静默处理缓存错误
        }

        return ApiResponse.success(details, statusCode: response.statusCode);
      } catch (parseError) {
        return ApiResponse.error('Bangumi 详情数据解析失败: ${parseError.toString()}');
      }
    } catch (e) {
      return ApiResponse.error('Bangumi 详情数据请求异常: ${e.toString()}');
    }
  }

  /// v2.1.40: http.get + 1 层 retry (网络/握手/超时错 retry 1 次).
  ///
  /// 删 _fetchBangumi / _secureSocketGet / _BgmSocketReader /
  /// dart:io / cf_optimizer 之后, 统一用 http.get, 行为跟 v2.1.22
  /// 之前的 tmdb_service 直连模式一致.
  static Future<http.Response?> _httpGetWithRetry(
    String url,
    Map<String, String> headers, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    try {
      return await http.get(Uri.parse(url), headers: headers).timeout(timeout);
    } catch (e) {
      try {
        return await http.get(Uri.parse(url), headers: headers).timeout(timeout);
      } catch (_) {
        return null;
      }
    }
  }
}
