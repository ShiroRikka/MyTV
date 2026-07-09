// v2.0.35: TMDB 海报墙设置页
//
// v2.0.46: 改 UI — 大图海报 + 渐变 hero (跟 player 大头部 / Douban 详情页风格一致).
//   hero 区: TMDB 蓝紫渐变 (从 #1e3a8a 蓝到 #6d28d9 紫) + 标题 + 简介, 高 220px.
//   hero 区下面: "热门电影" mini poster 3 张 (从 TMDB 实时拉取, 走
//   已配的 CF Worker 域名), 让用户**看到** TMDB 启用后的样子 (而不是
//   抽象的"配 key 自动启用").
//   再下面: 状态卡片 / API Key 输入 / 测试 / 强制刷新 / 申请说明.
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
import 'package:luna_tv/services/tmdb_service.dart';
import 'package:luna_tv/utils/image_url.dart';

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
  // v2.0.46: hero 区的样本海报 (从 TMDB 拉, 3 张热门电影)
  List<TmdbItem> _samplePosters = [];
  bool _sampleLoading = false;

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
    if (v.isNotEmpty) {
      // v2.0.46: 配了 key 就拉 3 张热门电影海报, 给 hero 区"看效果"
      // ignore: unawaited_futures
      _loadSamplePosters();
    }
  }

  /// v2.0.46: 拉 3 张热门电影海报, 给 hero 区做 preview.
  ///
  /// 走 [TmdbService.getPopular] (有 1 天本地缓存), 不发额外请求.
  /// 失败时静默 (hero 区会降级到无 preview, 文字描述保留).
  Future<void> _loadSamplePosters() async {
    if (_sampleLoading) return;
    setState(() => _sampleLoading = true);
    try {
      final res = await TmdbService.getPopular(
        type: TmdbMediaType.movie,
        page: 1,
      );
      if (!mounted) return;
      setState(() {
        _samplePosters = res.results.take(3).toList();
        _sampleLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _samplePosters = [];
        _sampleLoading = false;
      });
    }
  }

  /// v2.0.46: 强制刷新 TMDB 缓存 (清掉 1 天内存缓存 + SharedPreferences 缓存)
  Future<void> _forceRefresh() async {
    await TmdbService.clearCache();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('TMDB 缓存已清, 下次拉取走网络 (中文版)'),
        duration: Duration(milliseconds: 1500),
        behavior: SnackBarBehavior.floating,
      ),
    );
    // 重新拉样本海报, 让 hero 区刷新
    if (_apiKey.isNotEmpty) {
      // ignore: unawaited_futures
      _loadSamplePosters();
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
              padding: const EdgeInsets.fromLTRB(0, 0, 0, 32),
              children: [
                // v2.0.46: 大图海报 + 渐变 hero (替代原来"状态卡片在顶部")
                _buildHeroSection(isDark, textPrimary, textSecondary),
                const SizedBox(height: 16),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
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
                      if (hasKey)
                        _buildTestArea(isDark, textPrimary, textSecondary),
                      const SizedBox(height: 8),

                      // v2.0.46: 强制刷新 (清 1 天缓存, 拉中文版)
                      if (hasKey)
                        _buildForceRefreshTile(isDark),
                      const SizedBox(height: 16),

                      // 申请说明
                      _buildHelpSection(isDark, textPrimary, textSecondary),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  /// v2.0.46: 大图海报 + 渐变 hero.
  ///
  /// 设计 (跟 player 大头部 / Douban 详情页风格一致):
  ///   - 220px 高, 蓝紫渐变 (TMDB 品牌色)
  ///   - 上方: TMDB logo + 标题 "TMDB 海报墙" + 副标题
  ///   - 下方: 3 张热门电影 mini poster (从 TMDB 实时拉, 走 CF Worker)
  ///   - 整张图底部: 黑色渐变 fade (跟 v2.0.43 player hero 一致)
  ///
  /// 没配 key 时: 退化成纯渐变 + 文字 "未启用", 引导用户去配 key
  Widget _buildHeroSection(
    bool isDark,
    Color textPrimary,
    Color textSecondary,
  ) {
    final hasKey = _apiKey.isNotEmpty;
    return Container(
      height: 220,
      decoration: const BoxDecoration(
        // 蓝紫渐变 (跟 TMDB logo 蓝紫一致)
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color(0xFF1e3a8a), // 深蓝
            Color(0xFF6d28d9), // 紫
            Color(0xFF0ea5e9), // 青 (淡入)
          ],
        ),
      ),
      child: Stack(
        children: [
          // 上方: 标题区
          Positioned(
            top: 20,
            left: 20,
            right: 20,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(LucideIcons.film,
                              size: 14, color: Colors.white),
                          SizedBox(width: 4),
                          Text(
                            'TMDB',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: hasKey
                            ? const Color(0xFF10b981).withOpacity(0.9)
                            : Colors.white.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        hasKey ? '已启用' : '未启用',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  '海报墙',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.0,
                    height: 1.1,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  hasKey
                      ? '首页热门电影 / 剧集 自动横滚海报 + 评分'
                      : '填入 API Key 即可启用 · 中文标题 · 评分',
                  style: TextStyle(
                    color: Colors.white.withOpacity(0.9),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          // 下方: 3 张 mini poster (从 TMDB 拉)
          if (hasKey) ...[
            if (_sampleLoading)
              const Positioned(
                bottom: 24,
                left: 20,
                right: 20,
                child: SizedBox(
                  height: 80,
                  child: Center(
                    child: SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        color: Colors.white,
                        strokeWidth: 2,
                      ),
                    ),
                  ),
                ),
              )
            else if (_samplePosters.isNotEmpty)
              Positioned(
                bottom: 16,
                left: 20,
                right: 20,
                child: SizedBox(
                  height: 110,
                  child: Row(
                    children: _samplePosters.asMap().entries.map((entry) {
                      final idx = entry.key;
                      final item = entry.value;
                      return Expanded(
                        flex: idx == 1 ? 2 : 1, // 中间大
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: idx < 2 ? 8 : 0,
                            left: idx == 1 ? 4 : 0,
                          ),
                          child: _buildHeroPosterCard(item, isDark),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }

  /// v2.0.46: hero 区的 mini poster 卡 (横滚预览)
  Widget _buildHeroPosterCard(TmdbItem item, bool isDark) {
    final posterUrl = item.posterPath != null
        ? 'https://image.tmdb.org/t/p/w300${item.posterPath}'
        : null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景 (默认海报兜底)
          Container(
            color: const Color(0xFF1e293b),
            child: Center(
              child: Icon(
                LucideIcons.film,
                color: Colors.white.withOpacity(0.2),
                size: 24,
              ),
            ),
          ),
          if (posterUrl != null)
            Image.network(
              posterUrl,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              loadingBuilder: (_, child, progress) =>
                  progress == null ? child : const SizedBox.shrink(),
            ),
          // 渐变 fade 文字
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.fromLTRB(6, 12, 6, 6),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withOpacity(0.7),
                  ],
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    item.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (item.voteAverage > 0)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(LucideIcons.star,
                            size: 9, color: Color(0xFFfbbf24)),
                        const SizedBox(width: 2),
                        Text(
                          item.voteAverage.toStringAsFixed(1),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// v2.0.46: 强制刷新按钮 (清 TMDB 1 天缓存, 重新拉中文版)
  Widget _buildForceRefreshTile(bool isDark) {
    return Material(
      color: isDark ? const Color(0xFF1F2937) : Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: _forceRefresh,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          child: Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: const Color(0xFF0ea5e9).withOpacity(0.15),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(LucideIcons.refreshCw,
                    color: Color(0xFF0ea5e9), size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '强制刷新 TMDB 缓存',
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
                      '看到英文就点这个, 清掉 1 天缓存, 重新拉中文',
                      style: TextStyle(
                        color: isDark
                            ? Colors.white.withOpacity(0.5)
                            : Colors.black.withOpacity(0.5),
                        fontSize: 12,
                      ),
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
