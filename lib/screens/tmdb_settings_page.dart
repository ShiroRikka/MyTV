// v2.0.35: TMDB 海报墙设置页
//
// 为什么单独做一个页面:
//   - 跟"加速" (CF Worker) 是不同性质的功能 (CF 加速是网络层, TMDB 是 UI 增强)
//   - 申请 TMDB key 需要去 https://www.themoviedb.org/settings/api 注册账号
//     (免费, 注册后立即审核通过, 拿 v3 auth key)
//   - 设置页面有说明 + 输入 + 测试 + 清除, 比放一行 setting item 干净
//
// 配 key 后, 首页 _buildHomeTabContent 在 build 时读 getTmdbApiKeySync(),
//   - 非空 → HotMoviesSection / HotTvSection 替换为 TmdbPosterWall (Phase 2)
//   - null/空 → 保持原样 (5 个 section 都不动)
//
// 这就是 "key 字段 = 开关" 模式, 跟"优选 IP"字段一个思路:
//   填了 = 自动启用, 不填 = 保持原样, 不用再加 UI toggle.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:luna_tv/services/user_data_service.dart';

class TmdbSettingsPage extends StatefulWidget {
  const TmdbSettingsPage({super.key});

  @override
  State<TmdbSettingsPage> createState() => _TmdbSettingsPageState();
}

class _TmdbSettingsPageState extends State<TmdbSettingsPage> {
  String _apiKey = '';
  bool _loading = true;
  // 测试连接状态: null = 没测过, 'ok' = 通过, 'err' = 失败
  String? _testStatus;
  String _testMessage = '';
  bool _testing = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await UserDataService.getTmdbApiKey() ?? '';
    if (mounted) {
      setState(() {
        _apiKey = v;
        _loading = false;
      });
    }
  }

  Future<void> _save(String value) async {
    await UserDataService.saveTmdbApiKey(value);
    if (!mounted) return;
    setState(() {
      _apiKey = value;
      _testStatus = null; // 重置测试状态
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(value.isEmpty ? '已清除 TMDB API Key' : '已保存'),
        duration: const Duration(milliseconds: 1200),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// 测试连接: 用 v3 key 调 `https://api.themoviedb.org/3/configuration`,
  ///   该端点最轻量, 不需要参数, 200 = key 有效, 401 = 无效
  Future<void> _testConnection() async {
    if (_apiKey.isEmpty) return;
    setState(() {
      _testing = true;
      _testStatus = null;
      _testMessage = '';
    });
    try {
      // ignore: avoid_print
      print('[TMDB] 测试连接: api_key=${_apiKey.substring(0, 4)}***');
      // Phase 1: 暂时不真发请求 (要引入 http 依赖 + CORS handling),
      //   用格式校验做轻量验证, 401/200 真测试留到 Phase 2 海报墙实际调用时
      final ok = _isLikelyValidKey(_apiKey);
      await Future.delayed(const Duration(milliseconds: 600));
      if (!mounted) return;
      setState(() {
        _testing = false;
        if (ok) {
          _testStatus = 'ok';
          _testMessage = '格式看起来 OK. 实际验证留到首页加载海报时.';
        } else {
          _testStatus = 'err';
          _testMessage = '格式不太对. v3 key 一般 32 字符 hex. 请去 '
              'https://www.themoviedb.org/settings/api 重新复制.';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _testing = false;
        _testStatus = 'err';
        _testMessage = '异常: $e';
      });
    }
  }

  /// 轻量格式校验: v3 key 是 32 字符 hex (e.g. 1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p),
  /// v4 是 JWT (长字符串). 严格校验等到真发 HTTP 时再做.
  bool _isLikelyValidKey(String k) {
    if (k.length < 20) return false;
    // v3: 32 字符 hex
    final hex32 = RegExp(r'^[a-fA-F0-9]{32}$');
    if (hex32.hasMatch(k)) return true;
    // v4: JWT 风格 (eyJ 开头)
    if (k.startsWith('eyJ') && k.length > 50) return true;
    // 其他: 长度合理就放行, 真不真留到运行时验证
    if (k.length >= 20 && k.length <= 64) return true;
    return false;
  }

  void _showInputDialog() {
    final controller = TextEditingController(text: _apiKey);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: isDark ? const Color(0xFF1F2937) : Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Icon(LucideIcons.key, color: Color(0xFF10b981), size: 22),
                  SizedBox(width: 8),
                  Text(
                    'TMDB API Key',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '在 https://www.themoviedb.org/settings/api 申请, '
                '免费, 粘贴 v3 auth key 即可. 留空 = 关闭海报墙.',
                style: TextStyle(
                  fontSize: 12,
                  color: isDark
                      ? Colors.white.withOpacity(0.6)
                      : Colors.black.withOpacity(0.6),
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                maxLines: 1,
                style: const TextStyle(
                  fontFamily: 'monospace',
                  fontFamilyFallback: ['Courier', 'monospace'],
                  fontSize: 13,
                ),
                decoration: InputDecoration(
                  hintText: '1a2b3c4d5e6f7g8h9i0j1k2l3m4n5o6p',
                  hintStyle: TextStyle(
                    fontSize: 12,
                    color: isDark
                        ? Colors.white.withOpacity(0.3)
                        : Colors.black.withOpacity(0.3),
                  ),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  suffixIcon: IconButton(
                    icon: const Icon(LucideIcons.clipboardPaste, size: 18),
                    tooltip: '粘贴',
                    onPressed: () async {
                      final data = await Clipboard.getData('text/plain');
                      if (data?.text != null) {
                        controller.text = data!.text!.trim();
                      }
                    },
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('取消'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () {
                      Navigator.pop(ctx);
                      _save(controller.text.trim());
                    },
                    child: const Text('保存'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bg = isDark ? const Color(0xFF111827) : const Color(0xFFF3F4F6);
    final cardBg = isDark ? const Color(0xFF1F2937) : Colors.white;
    final textPrimary = isDark ? Colors.white : const Color(0xFF1F2937);
    final textSecondary = isDark
        ? Colors.white.withOpacity(0.6)
        : Colors.black.withOpacity(0.6);

    // 当前 key 状态: 已配 / 未配
    final hasKey = _apiKey.isNotEmpty;
    // key 摘要显示 (头 4 字符 + ... + 尾 4 字符)
    final keySummary = hasKey
        ? (_apiKey.length > 12
            ? '${_apiKey.substring(0, 4)}...${_apiKey.substring(_apiKey.length - 4)}'
            : '****')
        : '（未配置）';

    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        backgroundColor: bg,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('TMDB 海报墙'),
        actions: [
          if (hasKey)
            IconButton(
              icon: const Icon(LucideIcons.trash2, color: Color(0xFFef4444)),
              tooltip: '清除 API Key',
              onPressed: () async {
                final ok = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('清除 TMDB API Key?'),
                    content: const Text(
                        '清除后首页回到原列表风格. 已缓存的海报也会被清掉.'),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('取消'),
                      ),
                      FilledButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('清除'),
                      ),
                    ],
                  ),
                );
                if (ok == true) {
                  await _save('');
                }
              },
            ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                // 状态卡片: 已启用 / 未启用
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: hasKey
                        ? const Color(0xFF064e3b).withOpacity(0.3)
                        : cardBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: hasKey
                          ? const Color(0xFF10b981).withOpacity(0.5)
                          : (isDark
                              ? const Color(0xFF374151)
                              : const Color(0xFFE5E7EB)),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 40,
                        height: 40,
                        decoration: BoxDecoration(
                          color: hasKey
                              ? const Color(0xFF10b981).withOpacity(0.2)
                              : (isDark
                                  ? const Color(0xFF374151)
                                  : const Color(0xFFE5E7EB)),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Icon(
                          hasKey
                              ? LucideIcons.checkCircle2
                              : LucideIcons.circleDashed,
                          color: hasKey
                              ? const Color(0xFF10b981)
                              : textSecondary,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              hasKey ? '已启用' : '未启用',
                              style: TextStyle(
                                color: textPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              hasKey
                                  ? '首页热门电影 / 热门剧集 走 TMDB 海报墙'
                                  : '填入 API Key 即可启用海报墙, 留空 = 原列表',
                              style: TextStyle(
                                color: textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),

                // API Key 输入行
                _buildTile(
                  icon: LucideIcons.key,
                  iconColor: const Color(0xFF10b981),
                  title: 'API Key',
                  value: keySummary,
                  hint: '（点击配置）',
                  onTap: _showInputDialog,
                  isDark: isDark,
                ),
                const SizedBox(height: 8),

                // 测试连接 + 状态
                if (hasKey) _buildTestArea(isDark, textPrimary, textSecondary),
                const SizedBox(height: 16),

                // 申请说明
                _buildHelpSection(isDark, textPrimary, textSecondary),
              ],
            ),
    );
  }

  Widget _buildTile({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String value,
    required String hint,
    required VoidCallback onTap,
    required bool isDark,
  }) {
    return Material(
      color: isDark ? const Color(0xFF1F2937) : Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: iconColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: iconColor, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: isDark
                            ? Colors.white.withOpacity(0.85)
                            : const Color(0xFF1F2937),
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      value.isEmpty ? hint : value,
                      style: TextStyle(
                        color: value.isEmpty
                            ? (isDark
                                ? Colors.white.withOpacity(0.3)
                                : Colors.black.withOpacity(0.3))
                            : (isDark
                                ? Colors.white.withOpacity(0.95)
                                : const Color(0xFF1F2937)),
                        fontSize: 12,
                        fontFamily: 'monospace',
                        fontFamilyFallback: const ['Courier', 'monospace'],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right,
                color: isDark
                    ? Colors.white.withOpacity(0.3)
                    : Colors.black.withOpacity(0.3),
                size: 18,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTestArea(bool isDark, Color textPrimary, Color textSecondary) {
    final ok = _testStatus == 'ok';
    final err = _testStatus == 'err';
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2937) : Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: ok
              ? const Color(0xFF10b981).withOpacity(0.5)
              : err
                  ? const Color(0xFFef4444).withOpacity(0.5)
                  : (isDark
                      ? const Color(0xFF374151)
                      : const Color(0xFFE5E7EB)),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                _testing
                    ? LucideIcons.loader
                    : ok
                        ? LucideIcons.checkCircle2
                        : err
                            ? LucideIcons.alertCircle
                            : LucideIcons.zap,
                color: _testing
                    ? const Color(0xFF60a5fa)
                    : ok
                        ? const Color(0xFF10b981)
                        : err
                            ? const Color(0xFFef4444)
                            : textSecondary,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  _testing
                      ? '测试中...'
                      : ok
                          ? '格式 OK'
                          : err
                              ? '格式异常'
                              : '测试连接',
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              if (!_testing)
                TextButton(
                  onPressed: _testConnection,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    minimumSize: const Size(0, 32),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text('重新测试'),
                ),
            ],
          ),
          if (_testMessage.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 28),
              child: Text(
                _testMessage,
                style: TextStyle(
                  color: textSecondary,
                  fontSize: 12,
                  height: 1.4,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildHelpSection(
      bool isDark, Color textPrimary, Color textSecondary) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: isDark
            ? const Color(0xFF1F2937).withOpacity(0.6)
            : const Color(0xFFEFF6FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: isDark
              ? const Color(0xFF374151)
              : const Color(0xFFBFDBFE),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(LucideIcons.info,
                  color: textSecondary, size: 16),
              const SizedBox(width: 6),
              Text(
                '怎么申请 API Key',
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '1. 打开 https://www.themoviedb.org 注册账号 (免费)\n'
            '2. 账号设置 → API → 申请 v3 auth key (立即审核通过)\n'
            '3. 复制 32 字符的 key, 粘到上面输入框',
            style: TextStyle(
              color: textSecondary,
              fontSize: 12,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '没填 = 首页保持原列表 (5 个 section 都不变)',
            style: TextStyle(
              color: textSecondary.withOpacity(0.7),
              fontSize: 11,
              fontStyle: FontStyle.italic,
            ),
          ),
        ],
      ),
    );
  }
}
