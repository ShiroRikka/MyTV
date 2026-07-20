// lib/screens/source_browser_screen.dart
// v2.3.31: 源浏览器 screen
//   UX 参考 web LunaTV /source-browser (Next.js 14 + tailwind):
//     顶部: 源选择 pill (横向 scroll, 选中态 emerald-to-teal 渐变)
//     分类 pill (横向 scroll, 选中态 indigo-500 实心)
//     搜索框 (debounce 500ms, 跨分类可选)
//     主体: 2-3 列 grid (mobile 友好, 比 web 的 3-6 列窄)
//     无限滚动 (滚到底加载下一页)
//     点 item → 弹详情 bottom sheet (poster+title+year+actor+director+area+content+episodes+立即播放)
//     立即播放 → push PlayerScreen
//   web 走 server API, mobile 直接调源 API (跟现有 SearchService / DownstreamService 一致).

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';

import 'package:luna_tv/models/search_resource.dart';
import 'package:luna_tv/models/source_browser.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';
import 'package:luna_tv/services/search_service.dart';
import 'package:luna_tv/services/source_browser_service.dart';

class SourceBrowserScreen extends StatefulWidget {
  const SourceBrowserScreen({super.key});

  @override
  State<SourceBrowserScreen> createState() => _SourceBrowserScreenState();
}

class _SourceBrowserScreenState extends State<SourceBrowserScreen> {
  List<SearchResource> _resources = [];
  int? _selectedResourceIdx;
  List<SourceCategory> _categories = [];
  int? _selectedCategoryId;
  final List<SourceBrowserItem> _items = [];
  SourceBrowserPageMeta? _meta;
  bool _isLoadingCategories = false;
  bool _isLoadingPage = false;
  bool _isLoadingMore = false;
  String? _error;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  String _currentQuery = '';

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadResources();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadResources() async {
    final list = await SearchService.getActiveResources();
    if (!mounted) return;
    setState(() {
      _resources = list;
      if (list.isNotEmpty) {
        _selectedResourceIdx = 0;
        _loadCategories(list[0]);
      } else {
        _error = '暂无可用源 (请先在"源管理"添加)';
      }
    });
  }

  Future<void> _loadCategories(SearchResource r) async {
    setState(() {
      _isLoadingCategories = true;
      _categories = [];
      _selectedCategoryId = null;
      _items.clear();
      _meta = null;
      _error = null;
    });
    final cats = await SourceBrowserService.getCategories(r);
    if (!mounted) return;
    setState(() {
      _isLoadingCategories = false;
      _categories = cats ?? [];
      if (_categories.isNotEmpty) {
        _selectedCategoryId = _categories.first.typeId;
        _loadPage(reset: true);
      } else if (cats == null) {
        _error = '加载分类失败 (源 API `?ac=list` 错误)';
      } else {
        _error = '该源无分类 (可能 API 不支持)';
      }
    });
  }

  Future<void> _loadPage({bool reset = false, bool isLoadMore = false}) async {
    if (_selectedResourceIdx == null) return;
    final r = _resources[_selectedResourceIdx!];
    final typeId = _selectedCategoryId;
    final page = isLoadMore ? ((_meta?.page ?? 1) + 1) : 1;

    if (!isLoadMore) {
      setState(() {
        _isLoadingPage = true;
        _items.clear();
        _meta = null;
        _error = null;
      });
    } else {
      setState(() {
        _isLoadingMore = true;
      });
    }

    final result = _currentQuery.isEmpty
        ? await SourceBrowserService.getList(r, typeId: typeId ?? 0, page: page)
        : await SourceBrowserService.search(r,
            query: _currentQuery, typeId: typeId, page: page);

    if (!mounted) return;
    setState(() {
      _isLoadingPage = false;
      _isLoadingMore = false;
      if (result == null) {
        _error = '加载失败 (源 API 错误 / 网络不通)';
      } else {
        if (reset || !isLoadMore) {
          _items.clear();
        }
        _items.addAll(result.items);
        _meta = result.meta;
      }
    });
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_isLoadingMore || (_meta?.hasMore ?? false) == false) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _loadPage(isLoadMore: true);
    }
  }

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      if (_currentQuery != v.trim()) {
        setState(() {
          _currentQuery = v.trim();
        });
        _loadPage(reset: true);
      }
    });
  }

  void _onSourceTap(int idx) {
    if (_selectedResourceIdx == idx) return;
    setState(() {
      _selectedResourceIdx = idx;
      _currentQuery = '';
      _searchController.clear();
    });
    _loadCategories(_resources[idx]);
  }

  void _onCategoryTap(int typeId) {
    if (_selectedCategoryId == typeId) return;
    setState(() {
      _selectedCategoryId = typeId;
    });
    _loadPage(reset: true);
  }

  Future<void> _onItemTap(SourceBrowserItem item) async {
    if (_selectedResourceIdx == null) return;
    final r = _resources[_selectedResourceIdx!];
    final detail = await SourceBrowserService.getDetail(r, id: item.id);
    if (!mounted) return;
    if (detail == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('详情加载失败')),
      );
      return;
    }
    _showDetailSheet(detail, r);
  }

  void _showDetailSheet(SourceBrowserDetail d, SearchResource r) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (sheetCtx) => _DetailSheet(
        detail: d,
        resource: r,
        onPlay: () {
          Navigator.of(sheetCtx).pop();
          _playDetail(d, r);
        },
      ),
    );
  }

  void _playDetail(SourceBrowserDetail d, SearchResource r) {
    final videoInfo = VideoInfo(
      id: d.id,
      source: r.key,
      title: d.title,
      sourceName: r.name,
      year: d.year,
      cover: d.poster,
      index: 0,
      totalEpisodes: d.episodes.length,
      playTime: 0,
      totalTime: 0,
      saveTime: 0,
      searchTitle: d.title,
    );
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(videoInfo: videoInfo),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('源浏览器'),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              SourceBrowserService.clearCache();
              if (_selectedResourceIdx != null) {
                _loadCategories(_resources[_selectedResourceIdx!]);
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSourcePills(),
          _buildCategoryPills(),
          _buildSearchBar(),
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // -------- pills --------

  Widget _buildSourcePills() {
    if (_resources.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 52,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _resources.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, idx) {
          final r = _resources[idx];
          final selected = _selectedResourceIdx == idx;
          return ChoiceChip(
            label: Text(_stripEmoji(r.name), overflow: TextOverflow.ellipsis),
            selected: selected,
            onSelected: (_) => _onSourceTap(idx),
            selectedColor: Colors.teal,
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
            labelStyle: TextStyle(
              color: selected
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurface,
              fontSize: 13,
            ),
          );
        },
      ),
    );
  }

  Widget _buildCategoryPills() {
    if (_isLoadingCategories) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: SizedBox(
            height: 20,
            width: 20,
            child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    if (_categories.isEmpty) return const SizedBox.shrink();
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        itemCount: _categories.length,
        separatorBuilder: (_, __) => const SizedBox(width: 6),
        itemBuilder: (_, idx) {
          final c = _categories[idx];
          final selected = _selectedCategoryId == c.typeId;
          return ChoiceChip(
            label: Text(c.typeName),
            selected: selected,
            onSelected: (_) => _onCategoryTap(c.typeId),
            selectedColor: Colors.indigo,
            backgroundColor:
                Theme.of(context).colorScheme.surfaceContainerHighest,
            labelStyle: TextStyle(
              color: selected
                  ? Colors.white
                  : Theme.of(context).colorScheme.onSurface,
              fontSize: 12,
            ),
          );
        },
      ),
    );
  }

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        decoration: InputDecoration(
          hintText: '搜索该源...',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: _currentQuery.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    _onSearchChanged('');
                  },
                )
              : null,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(20),
            borderSide: BorderSide.none,
          ),
          filled: true,
          fillColor:
              Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      ),
    );
  }

  // -------- body --------

  Widget _buildBody() {
    if (_error != null && _items.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(_error!,
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ),
      );
    }
    if (_isLoadingPage && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return Center(
        child: Text('无结果',
            style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant)),
      );
    }
    return GridView.builder(
      controller: _scrollController,
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.55,
        crossAxisSpacing: 8,
        mainAxisSpacing: 12,
      ),
      itemCount: _items.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (_, idx) {
        if (idx >= _items.length) {
          return const Center(
              child: Padding(
            padding: EdgeInsets.all(16),
            child: SizedBox(
                width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          ));
        }
        return _ItemCard(item: _items[idx], onTap: () => _onItemTap(_items[idx]));
      },
    );
  }

  // -------- helpers --------

  /// 去除 emoji 前缀 (源 name 经常有 "🎬-爱奇艺-" 这种)
  String _stripEmoji(String s) {
    return s.replaceAll(RegExp(r'^[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]+\s*'),
        '');
  }
}

class _ItemCard extends StatelessWidget {
  final SourceBrowserItem item;
  final VoidCallback onTap;
  const _ItemCard({required this.item, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  CachedNetworkImage(
                    imageUrl: item.poster,
                    fit: BoxFit.cover,
                    placeholder: (_, __) => Container(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      child: const Center(
                          child: Icon(Icons.movie, color: Colors.white24, size: 32)),
                    ),
                    errorWidget: (_, __, ___) => Container(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest,
                      child: const Center(
                          child: Icon(Icons.broken_image, color: Colors.white24, size: 32)),
                    ),
                  ),
                  if (item.remarks.isNotEmpty)
                    Positioned(
                      right: 4,
                      bottom: 4,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 4, vertical: 2),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(item.remarks,
                            style: const TextStyle(
                                color: Colors.white,
                                fontSize: 9,
                                fontWeight: FontWeight.w500)),
                      ),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
          ),
          if (item.year.isNotEmpty)
            Text(item.year,
                style: TextStyle(
                    fontSize: 10,
                    color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

/// 详情 bottom sheet
class _DetailSheet extends StatelessWidget {
  final SourceBrowserDetail detail;
  final SearchResource resource;
  final VoidCallback onPlay;
  const _DetailSheet(
      {required this.detail, required this.resource, required this.onPlay});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DraggableScrollableSheet(
      initialChildSize: 0.85,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (_, scrollController) {
        return ListView(
          controller: scrollController,
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            // 顶部拖动条
            Center(
              child: Container(
                width: 40,
                height: 4,
                margin: const EdgeInsets.only(bottom: 12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.onSurfaceVariant
                      .withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 顶部: 海报 + 元数据
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: SizedBox(
                    width: 110,
                    height: 160,
                    child: detail.poster.isNotEmpty
                        ? CachedNetworkImage(
                            imageUrl: detail.poster,
                            fit: BoxFit.cover,
                            errorWidget: (_, __, ___) => Container(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: const Icon(Icons.broken_image),
                            ),
                          )
                        : Container(
                            color: theme.colorScheme.surfaceContainerHighest,
                            child: const Icon(Icons.movie, size: 32),
                          ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(detail.title,
                          style: theme.textTheme.titleMedium
                              ?.copyWith(fontWeight: FontWeight.bold)),
                      const SizedBox(height: 6),
                      if (detail.year.isNotEmpty)
                        _kv('年份', detail.year),
                      if (detail.typeName.isNotEmpty)
                        _kv('类型', detail.typeName),
                      if (detail.area.isNotEmpty) _kv('地区', detail.area),
                      if (detail.lang.isNotEmpty) _kv('语言', detail.lang),
                      if (detail.actor.isNotEmpty)
                        _kv('演员', detail.actor),
                      if (detail.director.isNotEmpty)
                        _kv('导演', detail.director),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // 简介
            if (detail.content.isNotEmpty) ...[
              Text('简介',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(_stripHtml(detail.content),
                  style: theme.textTheme.bodyMedium),
              const SizedBox(height: 16),
            ],
            // 选集
            if (detail.episodes.isNotEmpty) ...[
              Text('选集 (${detail.episodes.length}集)',
                  style: theme.textTheme.titleSmall
                      ?.copyWith(fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: detail.episodes
                    .map((e) => Chip(
                          label: Text(e.name,
                              style: const TextStyle(fontSize: 12)),
                          visualDensity: VisualDensity.compact,
                        ))
                    .toList(),
              ),
              const SizedBox(height: 16),
            ],
            // 立即播放
            FilledButton.icon(
              icon: const Icon(Icons.play_arrow),
              label: const Text('立即播放'),
              style: FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  backgroundColor: Colors.teal),
              onPressed: onPlay,
            ),
          ],
        );
      },
    );
  }

  Widget _kv(String k, String v) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: RichText(
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          text: TextSpan(
            style: TextStyle(
                fontSize: 12,
                color: Theme.of(context).colorScheme.onSurfaceVariant),
            children: [
              TextSpan(text: '$k: '),
              TextSpan(
                text: v,
                style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface),
              ),
            ],
          ),
        ),
      );

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .trim();
  }
}
