import 'dart:convert';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:luna_tv/services/diary_service.dart';
import 'package:luna_tv/services/user_data_service.dart';

class VersionService {
  static const String githubRepoUrl = 'https://github.com/ShiroRikka/MyTV';
  static const String githubApiUrl = 'https://api.github.com/repos/ShiroRikka/MyTV/releases/latest';
  static const String _lastCheckKey = 'last_version_check';
  static const String _dismissedVersionKey = 'dismissed_version';

  /// 检查是否有新版本（启动自动调用）
  static Future<VersionInfo?> checkForUpdate() async {
    return checkForUpdateImpl(auto: true);
  }

  /// 手动检查更新（用户点击菜单按钮）
  static Future<VersionInfo?> checkForUpdateManual() async {
    return checkForUpdateImpl(auto: false);
  }

  /// 核心检查更新实现
  static Future<VersionInfo?> checkForUpdateImpl({required bool auto}) async {
    try {
      // 获取当前运行的 App 版本
      final packageInfo = await PackageInfo.fromPlatform();
      final currentVersion = packageInfo.version;

      // GitHub API URL 优先走 worker 代理
      final apiUrl = UserDataService.buildGithubApiUrl(githubApiUrl);

      // 从 GitHub API 获取最新 Release
      final response = await http.get(
        Uri.parse(apiUrl),
        headers: {
          'Accept': 'application/vnd.github.v3+json',
        },
      ).timeout(const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final data = json.decode(response.body) as Map<String, dynamic>;
        final tagName = (data['tag_name'] as String?) ?? '';
        final latestVersion = tagName.startsWith('v') || tagName.startsWith('V')
            ? tagName.substring(1)
            : tagName;
        final releaseNotes = (data['body'] as String?) ?? '';

        // 从 assets 提取 .apk 直链
        String? apkDownloadUrl;
        final assets = data['assets'] as List<dynamic>?;
        if (assets != null) {
          for (final asset in assets) {
            if (asset is Map<String, dynamic>) {
              final name = (asset['name'] as String?) ?? '';
              final url = (asset['browser_download_url'] as String?) ?? '';
              if (name.toLowerCase().endsWith('.apk') && url.isNotEmpty) {
                apkDownloadUrl = UserDataService.buildGithubReleaseAssetUrl(url);
                break;
              }
            }
          }
        }
        final releasePageUrl = data['html_url'] as String?;

        DiaryService.add('[Version] check: current=$currentVersion, latest=$latestVersion');

        // 比较版本号：如果线上版本确实高于当前版本，返回 VersionInfo 触发弹窗
        if (_isNewerVersion(currentVersion, latestVersion)) {
          return VersionInfo(
            currentVersion: currentVersion,
            latestVersion: latestVersion,
            releaseNotes: releaseNotes,
            apkDownloadUrl: apkDownloadUrl,
            releasePageUrl: releasePageUrl,
          );
        }
      }
      return null;
    } catch (e) {
      DiaryService.add('[Version] check error: $e');
      return null;
    }
  }

  /// 获取 GitHub Release 页面 URL
  static String getReleaseUrl(String version) {
    return '$githubRepoUrl/releases/tag/v$version';
  }

  /// 安全比较版本号，支持剥离 v、构建号与预发布标签
  static bool _isNewerVersion(String current, String latest) {
    try {
      String clean(String v) {
        var s = v.trim();
        if (s.startsWith('v') || s.startsWith('V')) s = s.substring(1);
        if (s.contains('+')) s = s.split('+')[0];
        if (s.contains('-')) s = s.split('-')[0];
        return s;
      }

      final cClean = clean(current);
      final lClean = clean(latest);

      final cParts = cClean.split('.').map((p) => int.tryParse(p) ?? 0).toList();
      final lParts = lClean.split('.').map((p) => int.tryParse(p) ?? 0).toList();

      final maxLen = cParts.length > lParts.length ? cParts.length : lParts.length;
      for (int i = 0; i < maxLen; i++) {
        final c = i < cParts.length ? cParts[i] : 0;
        final l = i < lParts.length ? lParts[i] : 0;
        if (l > c) return true;
        if (l < c) return false;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  /// 标记用户已忽略某个版本
  static Future<void> dismissVersion(String version) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_dismissedVersionKey, version);
  }

  /// 清除忽略记录
  static Future<void> clearDismissedVersion() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_dismissedVersionKey);
  }
}

class VersionInfo {
  final String currentVersion;
  final String latestVersion;
  final String releaseNotes;
  final String? apkDownloadUrl;
  final String? releasePageUrl;

  VersionInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseNotes,
    this.apkDownloadUrl,
    this.releasePageUrl,
  });
}
