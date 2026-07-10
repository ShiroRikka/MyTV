// v2.0.78: 豆瓣大头部 — 给 player_screen「选源播放」详情页用
//
// 背景 (v2.0.77 → v2.0.78 演化):
//   v2.0.77: 删了 TMDB, 只把豆瓣 cover URL 升到 l_ratio_poster, 详情页
//            还是走 _buildPosterHeader (110x150 小海报布局). 用户反馈
//            "豆瓣大海报在哪和 tmdb 一样啊" — 期望像 TMDB 那种大头部
//            视觉 (大背景 + 大海报 + 标题/年份/简介).
//   v2.0.78: 加这个 DoubanDetailHeader, 沿用 v2.0.43 TMDB hero 的
//            布局思路 (rounded 容器 + 大背景 + 前景 150x225 海报 +
//            右侧文字), 但去掉 TMDB 依赖:
//              - **手机 (< 600)**: 2:3 竖版海报整张当背景, 渐变
//                压暗 (top 0.2 → bottom 0.85 black), 标题/年份/源
//                浮在底部. 海报本身就是主体, 没有前景"大竖海报"
//                元素 (省得跟背景重复).
//              - **平板 (>= 600)**: 21:9 横版, 左侧 150x225 大竖海报
//                (前景主体) + 右侧渐变背景 + 标题/年份/源.
//              - **共用**: 数据源还是 widget.videoInfo (标题/年份/
//                sourceName/cover), 不发额外 API 请求 — 豆瓣没公开
//                API 能拿 overview/集数, 之前 TMDB 那部分在 v2.0.77
//                删了, 没必要再为豆瓣接一个.
//              - **登录豆瓣后** (cookie 有效) → isDoubanLoggedIn() = true
//                → 走这个大头部; **没登录** → 走回 _buildPosterHeader
//                (110x150 小海报, 行为完全不变).
//
// 数据流 (无网络):
//   1. widget.videoInfo.cover  → getImageUrl(cover, source) 自动
//      升级到 l_ratio_poster (登录态下, 见 image_url.dart v2.0.77 改的)
//   2. 标题/年份/sourceName 直接从 widget.videoInfo 拿 (源 API 已有)
//   3. 渐变蒙版 + 圆角 16 + 阴影, 跟 TMDB hero 视觉一致.
//
// 用法 (player_screen 调用):
//   if (UserDataService.isDoubanLoggedIn() && widget.videoInfo.cover.isNotEmpty)
//     DoubanDetailHeader(
//       title: widget.videoInfo.title,
//       year: widget.videoInfo.year,
//       cover: widget.videoInfo.cover,
//       source: widget.videoInfo.source,
//       sourceName: widget.videoInfo.sourceName,
//     )
//   else
//     _buildPosterHeader(isDark),

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/image_url.dart';
import 'package:provider/provider.dart';

/// v2.0.78: 豆瓣大头部
///
/// 登录豆瓣 (cookie 有效) 时, 在 player_screen 详情页展示:
/// - 手机: 整张竖版海报 + 渐变压暗 + 底部标题
/// - 平板: 21:9 横版 + 左侧大竖海报 + 右侧渐变背景 + 标题
///
/// 没登录: 调用方走 _buildPosterHeader (小海报), 行为不变。
class DoubanDetailHeader extends StatefulWidget {
  final String title;
  final String? year;
  final String cover; // douban / bangumi URL (v2.0.77 自动升 l_ratio)
  final String source; // 'douban' / 'bangumi'
  final String? sourceName; // 「默认: 豆瓣」那行

  const DoubanDetailHeader({
    super.key,
    required this.title,
    this.year,
    required this.cover,
    required this.source,
    this.sourceName,
  });

  @override
  State<DoubanDetailHeader> createState() => _DoubanDetailHeaderState();
}

class _DoubanDetailHeaderState extends State<DoubanDetailHeader> {
  @override
  Widget build(BuildContext context) {
    final isDark = context.watch<ThemeService>().isDarkMode;
    final isTablet = MediaQuery.of(context).size.width >= 600;

    if (widget.cover.isEmpty) {
      // cover 为空 (源没给), 不进大头部逻辑 — 调用方应该已经过滤
      return const SizedBox.shrink();
    }

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        color: isDark ? const Color(0xFF1F2937) : const Color(0xFFE5E7EB),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.18),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: isTablet ? _buildTabletLayout(isDark) : _buildPhoneLayout(isDark),
    );
  }

  /// v2.0.78: 手机 — 2:3 竖版海报整张当背景 + 渐变压暗 + 底部标题
  ///
  /// 海报本身就是主体元素, 没有前景"大竖海报"重复展示.
  /// 渐变让标题清晰可读, 同时保留海报的视觉冲击.
  Widget _buildPhoneLayout(bool isDark) {
    return AspectRatio(
      aspectRatio: 2 / 3, // 标准海报比例 (跟 l_ratio_poster 一致)
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 背景: 整张海报 (登录态下, getImageUrl 自动升 l_ratio)
          FutureBuilder<String>(
            future: getImageUrl(widget.cover, widget.source),
            builder: (context, snapshot) {
              final imageUrl = snapshot.data ?? widget.cover;
              final headers = getImageRequestHeaders(imageUrl, widget.source);
              return CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                httpHeaders: headers,
                placeholder: (c, u) => Container(
                  color: isDark
                      ? const Color(0xFF1F2937)
                      : const Color(0xFFE5E7EB),
                ),
                errorWidget: (c, u, e) => Container(
                  color: isDark
                      ? const Color(0xFF1F2937)
                      : const Color(0xFFE5E7EB),
                  child: const Icon(Icons.movie_outlined,
                      color: Colors.grey, size: 48),
                ),
              );
            },
          ),
          // 2) 渐变蒙版: 顶部 0.2 → 底部 0.85 (黑色), 让底部标题清晰
          //    中间留 0.45 过渡区给海报"主体"留出可见空间
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.20),
                  Colors.black.withOpacity(0.45),
                  Colors.black.withOpacity(0.85),
                ],
                stops: const [0.0, 0.45, 1.0],
              ),
            ),
          ),
          // 3) 底部: 标题 + 年份 + 源
          Positioned(
            left: 16,
            right: 16,
            bottom: 16,
            child: _buildMetaColumn(alignEnd: false),
          ),
        ],
      ),
    );
  }

  /// v2.0.78: 平板 — 21:9 横版, 左侧 150x225 大竖海报 + 右侧渐变 + 标题
  ///
  /// v2.0.51 平板 21:9 比例, 给选集 / source list 留出空间.
  Widget _buildTabletLayout(bool isDark) {
    return AspectRatio(
      aspectRatio: 21 / 9,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 1) 背景: 整张海报 + 重度渐变 (跟 v2.0.51 TMDB hero 一致)
          FutureBuilder<String>(
            future: getImageUrl(widget.cover, widget.source),
            builder: (context, snapshot) {
              final imageUrl = snapshot.data ?? widget.cover;
              final headers = getImageRequestHeaders(imageUrl, widget.source);
              return CachedNetworkImage(
                imageUrl: imageUrl,
                fit: BoxFit.cover,
                httpHeaders: headers,
                placeholder: (c, u) => Container(
                  color: isDark
                      ? const Color(0xFF1F2937)
                      : const Color(0xFFE5E7EB),
                ),
                errorWidget: (c, u, e) => Container(
                  color: isDark
                      ? const Color(0xFF1F2937)
                      : const Color(0xFFE5E7EB),
                ),
              );
            },
          ),
          DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Colors.black.withOpacity(0.35),
                  Colors.black.withOpacity(0.65),
                  Colors.black.withOpacity(0.90),
                ],
                stops: const [0.0, 0.55, 1.0],
              ),
            ),
          ),
          // 2) 前景: 左侧 150x225 大竖海报 (主元素) + 右侧标题/年份/源
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 左侧大竖海报 (主元素)
                ClipRRect(
                  borderRadius: BorderRadius.circular(12),
                  child: SizedBox(
                    width: 150,
                    height: 225,
                    child: FutureBuilder<String>(
                      future: getImageUrl(widget.cover, widget.source),
                      builder: (context, snapshot) {
                        final imageUrl = snapshot.data ?? widget.cover;
                        final headers =
                            getImageRequestHeaders(imageUrl, widget.source);
                        return CachedNetworkImage(
                          imageUrl: imageUrl,
                          fit: BoxFit.cover,
                          httpHeaders: headers,
                          memCacheWidth: (150 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          memCacheHeight: (225 *
                                  MediaQuery.of(context).devicePixelRatio)
                              .round(),
                          placeholder: (c, u) => Container(
                            color: isDark
                                ? const Color(0xFF1F2937)
                                : const Color(0xFFE5E7EB),
                          ),
                          errorWidget: (c, u, e) => Container(
                            color: isDark
                                ? const Color(0xFF1F2937)
                                : const Color(0xFFE5E7EB),
                            child: const Icon(Icons.movie_outlined,
                                color: Colors.grey, size: 48),
                          ),
                        );
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                // 右侧: 标题 + 年份 + 源
                Expanded(
                  child: _buildMetaColumn(alignEnd: false),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// v2.0.78: 标题 + 年份 + 源 — 浮在渐变蒙版上, 白字带阴影
  ///
  /// 共用手机/平板布局, 文字颜色 + 阴影一致 (跟 TMDB hero v2.0.43 风格).
  Widget _buildMetaColumn({required bool alignEnd}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.end, // 底部对齐
      mainAxisSize: MainAxisSize.max,
      children: [
        // 大标题
        Text(
          widget.title,
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            height: 1.2,
            shadows: [
              Shadow(color: Colors.black87, blurRadius: 6),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // 年份 + 源
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            if (widget.year != null && widget.year!.isNotEmpty)
              _buildMetaChip(widget.year!),
            if (widget.sourceName != null && widget.sourceName!.isNotEmpty)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.cloud_outlined,
                      size: 11, color: Colors.white.withOpacity(0.75)),
                  const SizedBox(width: 3),
                  Text(
                    '默认: ${widget.sourceName}',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withOpacity(0.75),
                      shadows: const [
                        Shadow(color: Colors.black54, blurRadius: 4),
                      ],
                    ),
                  ),
                ],
              ),
          ],
        ),
      ],
    );
  }

  /// v2.0.78: 年份 chip — 半透明白底 + 阴影, 跟 TMDB hero 一致
  Widget _buildMetaChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.18),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withOpacity(0.25)),
      ),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: Colors.white,
          shadows: [Shadow(color: Colors.black54, blurRadius: 4)],
        ),
      ),
    );
  }
}
