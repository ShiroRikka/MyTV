// lib/screens/source_browser_screen.dart
//
// v2.3.32 重大改: 1:1 复刻 web LunaTV /source-browser (Next.js 14)
//
//   跟 v2.3.31 比, v2.3.32 加的关键点:
//   1. 排序下拉 (5 选: 默认 / 标题 A→Z / 标题 Z→A / 年份↑ / 年份↓)
//      - web: <select value={sortBy}>; mobile: PopupMenuButton + ListTile
//      - 跟 web 一样影响当前页 items (sort client-side, 不重新打源 API)
//   2. 年份筛选下拉
//      - 候选年份从当前页 items 自动取 (跟 web availableYears 同款)
//      - 没选 = "全部年份" (跟 web 同款)
//   3. 关键词筛选 (filterKeyword)
//      - 在当前已加载 items 里按 title+remarks 过滤 (client-side)
//      - 跟 web filteredAndSorted 同源
//   4. 视口自动填满 (autoFill on empty viewport)
//      - 跟 web 一样: 滚到底仍不够一屏时, 连翻 5 页 (400ms 节流)
//      - 解决分类只有 1-2 页时空白视口体验差
//   5. 节流翻页 (700ms)
//      - 跟 web 一样: 700ms 内不重复打 fetch
//   6. 详情预览**全屏 dialog** (替换 v2.3.31 bottom sheet)
//      - 跟 web preview modal 同款: 顶 header + 滚动内容 + 底「立即播放」
//      - 集成豆瓣 (DoubanService.getDoubanDetails): 评分/导演/编剧/演员/
//        类型/国家/语言/首播/集数/剧情简介
//      - 集成 Bangumi (BangumiService.getBangumiDetails): 自动判 6 位
//        douban_id 走 Bangumi, 显示评分/标签/infobox/简介
//      - 失败/没 douban_id: 静默 fallback 到源 detail.content
//   7. 不再 auto-select 第一个源
//      - v2.3.31: 进页面就 _selectedResourceIdx = 0 (默选第一个源)
//      - v2.3.32: 改成纯用户主动选, 空源时显示「请先在源管理添加源」
//      - 跟 web /source-browser useEffect 自动选第一个有区别 (web
//        自动选, mobile 改成不自动选, 体现"第一源不固定"原则)
//
// 不变的东西:
//   - 源 API 协议 (ac=list / ac=videolist&t=X&pg=N / ac=videolist&wd=Q
//     &pg=N / ac=videolist&ids=ID) 跟 v2.3.31 一致, 跟 web 1:1
//   - SourceBrowserService 4 个方法签名不变 (getCategories / getList /
//     search / getDetail), 内部 GBK/UTF-8 解码 + 5 分钟内存 cache 不变
//   - UserDataService 配的代理 / 加速 链路不变, detail 端
//     `ac=videolist&ids=ID` 跟 web /api/source-browser/* 拼 URL 1:1

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:luna_tv/models/bangumi.dart';
import 'package:luna_tv/models/douban_movie.dart';
import 'package:luna_tv/models/search_resource.dart';
import 'package:luna_tv/models/source_browser.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';
import 'package:luna_tv/services/bangumi_service.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/services/search_service.dart';
import 'package:luna_tv/services/source_browser_service.dart';

/// v2.3.32: 排序选项, 跟 web /source-browser <select> 5 个 option 1:1
enum _SortBy {
  defaultSort('default', '默认'),
  titleAsc('title-asc', '标题 A→Z'),
  titleDesc('title-desc', '标题 Z→A'),
  yearAsc('year-asc', '年份↑'),
  yearDesc('year-desc', '年份↓');

  final String value;
  final String label;
  const _SortBy(this.value, this.label);
}

/// v2.3.32: mode 跟 web source-browser 同款 (URL ?mode=)
enum _Mode { category, search }

class SourceBrowserScreen extends StatefulWidget {
  const SourceBrowserScreen({super.key});

  @override
  State<SourceBrowserScreen> createState() => _SourceBrowserScreenState();
}

class _SourceBrowserScreenState extends State<SourceBrowserScreen> {
  // -------- source / category / items state --------
  List<SearchResource> _resources = const [];
  String? _selectedSourceKey; // v2.3.32 改: null = 用户没选 (不再是 0)
  List<SourceCategory> _categories = const [];
  int? _selectedCategoryId;
  final List<SourceBrowserItem> _items = [];
  SourceBrowserPageMeta? _meta;
  bool _isLoadingSources = true;
  bool _isLoadingCategories = false;
  bool _isLoadingPage = false;
  bool _isLoadingMore = false;
  String? _error;
  bool _loadSourcesError = false;

  // -------- search / sort / filter state --------
  _Mode _mode = _Mode.category;
  String _searchQuery = '';
  _SortBy _sortBy = _SortBy.defaultSort;
  String? _filterYear; // null = 全部年份
  String _filterKeyword = '';
  Timer? _searchDebounce;

  // -------- infinite scroll throttle (web 700ms) --------
  DateTime _lastFetchAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _autoFillInProgress = false;

  // -------- scroll controller --------
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _filterKeywordController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    _loadSources();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _searchController.dispose();
    _filterKeywordController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  // -------- data load: sources --------

  Future<void> _loadSources() async {
    setState(() {
      _isLoadingSources = true;
      _loadSourcesError = false;
      _error = null;
    });
    try {
      final list = await SearchService.getActiveResources();
      if (!mounted) return;
      setState(() {
        _resources = list;
        _isLoadingSources = false;
        // v2.3.32 改: **不默选第一个源**, 让用户主动选
        // - 跟 web 不同 (web useEffect 自动选第一个, mobile 改成不自动)
        // - 体现"第一源不固定" — app 不预设任何源
        // - 用户没选时显示 "请先在源管理添加源" 引导
        _selectedSourceKey = null;
        _categories = const [];
        _selectedCategoryId = null;
        _items.clear();
        _meta = null;
        if (list.isEmpty) {
          _error = '暂无可用源\n请先在「源管理」中添加订阅';
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingSources = false;
        _loadSourcesError = true;
        _error = '加载源列表失败: $e';
      });
    }
  }

  // -------- data load: categories --------

  Future<void> _loadCategories(String sourceKey) async {
    final idx = _resources.indexWhere((r) => r.key == sourceKey);
    if (idx < 0) return;
    final r = _resources[idx];
    setState(() {
      _isLoadingCategories = true;
      _categories = const [];
      _selectedCategoryId = null;
      _items.clear();
      _meta = null;
      _error = null;
      _searchQuery = '';
      _searchController.clear();
      _filterYear = null;
    });
    final cats = await SourceBrowserService.getCategories(r);
    if (!mounted) return;
    setState(() {
      _isLoadingCategories = false;
      _categories = cats ?? const [];
      if (_categories.isNotEmpty) {
        _selectedCategoryId = _categories.first.typeId;
        _loadPage(reset: true);
      } else if (cats == null) {
        _error = '加载分类失败 (源 API `?ac=list` 错误)';
      } else {
        _error = '该源无分类 (可能 API 不支持 `?ac=list`)';
      }
    });
  }

  // -------- data load: page (list / search) --------

  Future<void> _loadPage({bool reset = false, bool isLoadMore = false}) async {
    final key = _selectedSourceKey;
    if (key == null) return;
    final idx = _resources.indexWhere((r) => r.key == key);
    if (idx < 0) return;
    final r = _resources[idx];
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

    final SourceBrowserPage? result = _searchQuery.isEmpty
        ? await SourceBrowserService.getList(r, typeId: typeId ?? 0, page: page)
        : await SourceBrowserService.search(r,
            query: _searchQuery, typeId: typeId, page: page);

    if (!mounted) return;
    setState(() {
      _isLoadingPage = false;
      _isLoadingMore = false;
      if (result == null) {
        _error = '加载失败 (源 API 错误 / 网络不通)';
      } else {
        _items.addAll(result.items);
        _meta = result.meta;
      }
      _lastFetchAt = DateTime.now();
    });
  }

  // -------- infinite scroll --------

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    if (_isLoadingMore) return;
    if (!(_meta?.hasMore ?? false)) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 300) {
      _throttledLoadMore();
    }
  }

  /// 700ms 节流 (跟 web lastFetchAtRef 700ms 1:1)
  Future<void> _throttledLoadMore() async {
    final now = DateTime.now();
    if (now.difference(_lastFetchAt).inMilliseconds < 700) return;
    _lastFetchAt = now;
    await _loadPage(isLoadMore: true);
    if (!mounted) return;
    // 翻页后自动试填视口
    _tryAutoFill();
  }

  /// v2.3.32 改: 视口自动填满, 跟 web tryAutoFill 1:1
  /// 内容高度 < 视口高度 + 100px 时, 连翻 5 页 (400ms 节流), 直到能滚
  Future<void> _tryAutoFill() async {
    if (_autoFillInProgress) return;
    if (_isLoadingPage || _isLoadingMore) return;
    if (!(_meta?.hasMore ?? false)) return;
    if (!_scrollController.hasClients) return;
    final maxScroll = _scrollController.position.maxScrollExtent;
    final viewport = _scrollController.position.viewportDimension;
    // 当前内容 + viewport < 视口 + 100px, 说明没滚动
    if (maxScroll > viewport + 100) return;

    _autoFillInProgress = true;
    try {
      for (int i = 0; i < 5; i++) {
        if (!(_meta?.hasMore ?? false)) break;
        if (_isLoadingPage || _isLoadingMore) break;
        final now = DateTime.now();
        if (now.difference(_lastFetchAt).inMilliseconds <= 400) break;
        _lastFetchAt = now;
        await _loadPage(isLoadMore: true);
        if (!mounted) break;
        if (!_scrollController.hasClients) break;
        final newMax = _scrollController.position.maxScrollExtent;
        if (newMax > _scrollController.position.viewportDimension + 100) break;
      }
    } finally {
      _autoFillInProgress = false;
    }
  }

  // -------- search / sort / filter handlers --------

  void _onSearchChanged(String v) {
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final newMode = v.trim().isEmpty ? _Mode.category : _Mode.search;
      if (_searchQuery == v.trim() && _mode == newMode) return;
      setState(() {
        _searchQuery = v.trim();
        _mode = newMode;
      });
      if (_selectedSourceKey != null) {
        _loadPage(reset: true);
      }
    });
  }

  void _onSourceTap(String key) {
    if (_selectedSourceKey == key) return;
    setState(() {
      _selectedSourceKey = key;
    });
    _loadCategories(key);
  }

  void _onCategoryTap(int typeId) {
    if (_selectedCategoryId == typeId) return;
    setState(() {
      _selectedCategoryId = typeId;
    });
    _loadPage(reset: true);
  }

  // -------- derived: filtered + sorted items (client-side) --------
  // 跟 web filteredAndSorted useMemo 1:1
  List<SourceBrowserItem> get _visibleItems {
    var arr = List<SourceBrowserItem>.from(_items);
    if (_filterKeyword.trim().isNotEmpty) {
      final kw = _filterKeyword.trim().toLowerCase();
      arr = arr.where((it) {
        return it.title.toLowerCase().contains(kw) ||
            it.remarks.toLowerCase().contains(kw);
      }).toList();
    }
    if (_filterYear != null && _filterYear!.isNotEmpty) {
      arr = arr.where((it) => it.year == _filterYear).toList();
    }
    switch (_sortBy) {
      case _SortBy.titleAsc:
        arr.sort((a, b) => a.title.compareTo(b.title));
        break;
      case _SortBy.titleDesc:
        arr.sort((a, b) => b.title.compareTo(a.title));
        break;
      case _SortBy.yearAsc:
        arr.sort(
            (a, b) => (int.tryParse(a.year) ?? 0) - (int.tryParse(b.year) ?? 0));
        break;
      case _SortBy.yearDesc:
        arr.sort(
            (a, b) => (int.tryParse(b.year) ?? 0) - (int.tryParse(a.year) ?? 0));
        break;
      case _SortBy.defaultSort:
        break;
    }
    return arr;
  }

  // 候选年份 (当前页所有 item 的 year 字段去重, 倒序)
  List<String> get _availableYears {
    final set = <String>{};
    for (final it in _items) {
      final y = it.year.trim();
      if (y.isNotEmpty) set.add(y);
    }
    final list = set.toList();
    list.sort((a, b) => (int.tryParse(b) ?? 0) - (int.tryParse(a) ?? 0));
    return list;
  }

  // -------- item tap → preview dialog --------

  Future<void> _onItemTap(SourceBrowserItem item) async {
    final key = _selectedSourceKey;
    if (key == null) return;
    final idx = _resources.indexWhere((r) => r.key == key);
    if (idx < 0) return;
    final r = _resources[idx];
    final detail = await SourceBrowserService.getDetail(r, id: item.id);
    if (!mounted) return;
    if (detail == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('详情加载失败')),
      );
      return;
    }
    // v2.3.32: 跟 v2.3.31 _playDetail 模式同款 — dialog 弹出来
    //   后, 播放按钮 onPlay 调 Navigator.of(dialogCtx).pop() 关掉
    //   dialog, 然后 _playDetail(d, r) 拿 screen 的 context push
    //   PlayerScreen. 这样 dialog 的 context 失效不影响 push.
    showDialog(
      context: context,
      barrierColor: Colors.black.withOpacity(0.6),
      builder: (dialogCtx) => _PreviewDialog(
        detail: detail,
        resource: r,
        onPlay: () {
          Navigator.of(dialogCtx).pop();
          _playDetail(detail, r);
        },
      ),
    );
  }

  /// 跟 v2.3.31 _playDetail 一致, 用 screen 的 context push
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
      // v2.3.32: 把 douban_id 透传给 player, 跟 _loadDoubanSummary
      //   / _loadTmdbBackdrop 联动 (VideoInfo.doubanId 是 String?)
      doubanId: d.vodDoubanId > 0 ? d.vodDoubanId.toString() : null,
    );
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => PlayerScreen(videoInfo: videoInfo)),
    );
  }

  // -------- build --------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('源浏览器'),
            if (_resources.isNotEmpty) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.teal.withOpacity(0.2),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${_resources.length} 个源',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ],
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: () {
              SourceBrowserService.clearCache();
              if (_selectedSourceKey != null) {
                _loadCategories(_selectedSourceKey!);
              } else {
                _loadSources();
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          _buildSourcePills(),
          if (_selectedSourceKey != null) ...[
            _buildSearchBar(),
            _buildFilterRow(),
            if (_mode == _Mode.category) _buildCategoryPills(),
          ],
          Expanded(child: _buildBody()),
        ],
      ),
    );
  }

  // -------- source pills --------

  Widget _buildSourcePills() {
    if (_isLoadingSources) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    if (_resources.isEmpty) {
      return const SizedBox.shrink();
    }
    return SizedBox(
      height: 56,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _resources.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (_, idx) {
          final r = _resources[idx];
          final selected = _selectedSourceKey == r.key;
          return ChoiceChip(
            label: Text(_stripEmoji(r.name), overflow: TextOverflow.ellipsis),
            selected: selected,
            onSelected: (_) => _onSourceTap(r.key),
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

  // -------- search bar --------

  Widget _buildSearchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _searchController,
              onChanged: _onSearchChanged,
              decoration: InputDecoration(
                hintText: '输入关键词并回车进行搜索; 清空回车恢复分类',
                prefixIcon: const Icon(Icons.search, size: 20),
                isDense: true,
                contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(20),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
              ),
            ),
          ),
          if (_searchQuery.isNotEmpty) ...[
            const SizedBox(width: 8),
            TextButton(
              onPressed: () {
                _searchController.clear();
                _onSearchChanged('');
              },
              child: const Text('清除'),
            ),
          ],
          const SizedBox(width: 4),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: _mode == _Mode.search
                  ? Colors.indigo.withOpacity(0.2)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              _mode == _Mode.search ? '搜索' : '分类',
              style: TextStyle(
                fontSize: 11,
                color: _mode == _Mode.search
                    ? Colors.indigo
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------- filter row (sort + year + keyword) --------
  // 跟 web 第二行 <select> 1:1: 排序 / 年份 / 地区·关键词

  Widget _buildFilterRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          // 排序下拉
          Expanded(
            child: PopupMenuButton<_SortBy>(
              initialValue: _sortBy,
              onSelected: (v) => setState(() => _sortBy = v),
              itemBuilder: (_) => _SortBy.values
                  .map((s) => PopupMenuItem(
                        value: s,
                        child: Text(s.label),
                      ))
                  .toList(),
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.sort, size: 16),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _sortBy.label,
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 年份下拉
          Expanded(
            child: PopupMenuButton<String?>(
              initialValue: _filterYear,
              onSelected: (v) => setState(() => _filterYear = v),
              itemBuilder: (_) {
                final list = <PopupMenuEntry<String?>>[
                  const PopupMenuItem<String?>(
                    value: null,
                    child: Text('全部年份'),
                  ),
                  if (_availableYears.isNotEmpty) const PopupMenuDivider(),
                ];
                for (final y in _availableYears) {
                  list.add(PopupMenuItem<String?>(value: y, child: Text(y)));
                }
                return list;
              },
              child: Container(
                height: 36,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.calendar_today, size: 14),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        _filterYear ?? '全部年份',
                        style: const TextStyle(fontSize: 12),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const Icon(Icons.arrow_drop_down, size: 18),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // 关键词筛选
          Expanded(
            child: SizedBox(
              height: 36,
              child: TextField(
                controller: _filterKeywordController,
                onChanged: (v) => setState(() => _filterKeyword = v),
                decoration: InputDecoration(
                  hintText: '地区/关键词',
                  prefixIcon: const Icon(Icons.filter_list, size: 16),
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 0),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide.none,
                  ),
                  filled: true,
                  fillColor:
                      Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // -------- category pills --------

  Widget _buildCategoryPills() {
    if (_isLoadingCategories) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
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

  // -------- body --------

  Widget _buildBody() {
    // 状态优先级: 空源错误 > loading > 错误 > 空结果 > grid
    if (_selectedSourceKey == null) {
      // v2.3.32 改: 没选源时显示引导 (空源 / 用户没主动选)
      if (_loadSourcesError) {
        return _buildCentered(
            icon: Icons.error_outline,
            color: Colors.red,
            title: '加载源失败',
            subtitle: _error);
      }
      if (_isLoadingSources) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_resources.isEmpty) {
        return _buildCentered(
            icon: Icons.source_outlined,
            color: Colors.grey,
            title: '暂无可用源',
            subtitle: '请先在「源管理」中添加订阅\napp 不会内置任何源');
      }
      return _buildCentered(
          icon: Icons.touch_app_outlined,
          color: Colors.teal,
          title: '请选择来源站',
          subtitle: '上方源列表选择一个开始浏览\napp 不预设任何源, 由你自选');
    }
    if (_error != null && _items.isEmpty) {
      return _buildCentered(
          icon: Icons.error_outline, color: Colors.red, title: '加载失败', subtitle: _error);
    }
    if (_isLoadingPage && _items.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_items.isEmpty) {
      return _buildCentered(
          icon: Icons.movie_filter_outlined,
          color: Colors.grey,
          title: '暂无内容',
          subtitle: '试试切其他分类 / 源 / 或清空筛选');
    }
    final visible = _visibleItems;
    if (visible.isEmpty) {
      return _buildCentered(
          icon: Icons.search_off,
          color: Colors.grey,
          title: '无匹配结果',
          subtitle: '清空筛选条件试试');
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
      itemCount: visible.length + (_isLoadingMore ? 1 : 0),
      itemBuilder: (_, idx) {
        if (idx >= visible.length) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2)),
            ),
          );
        }
        return _ItemCard(
          item: visible[idx],
          onTap: () => _onItemTap(visible[idx]),
        );
      },
    );
  }

  Widget _buildCentered({
    required IconData icon,
    required Color color,
    required String title,
    String? subtitle,
  }) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color.withOpacity(0.5)),
            const SizedBox(height: 12),
            Text(title,
                style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
            if (subtitle != null) ...[
              const SizedBox(height: 6),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 12,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _stripEmoji(String s) {
    return s.replaceAll(RegExp(r'^[\u{1F300}-\u{1FAFF}\u{2600}-\u{27BF}]+\s*'),
        '');
  }
}

// =====================================================================
// Item card (跟 v2.3.31 一致, 保留 2:3 海报 + 标题 + 年份 + 备注)
// =====================================================================

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
                          color: Colors.black.withOpacity(0.6),
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

// =====================================================================
// v2.3.32: 全屏 preview dialog (替换 v2.3.31 bottom sheet)
//
// 跟 web source-browser preview modal 1:1:
//   - 顶 header: icon + 标题 + 关闭按钮
//   - 滚动内容: 海报(左) + 元数据 + 描述 + 豆瓣/Bangumi section
//   - 底: 「立即播放」 按钮 (跟 web 一样 fill teal gradient)
//   - 集数列表不展示 (跟 web 一样, 用户原话要求)
// =====================================================================

class _PreviewDialog extends StatefulWidget {
  final SourceBrowserDetail detail;
  final SearchResource resource;
  /// v2.3.32: 跟 v2.3.31 _DetailSheet.onPlay 同款 — dialog 内部不
  ///   直接 navigate, 而是把 navigation 委托给 screen (用 screen
  ///   的 context push, 避免 dialog context 失效)
  final VoidCallback onPlay;
  const _PreviewDialog({
    required this.detail,
    required this.resource,
    required this.onPlay,
  });

  @override
  State<_PreviewDialog> createState() => _PreviewDialogState();
}

class _PreviewDialogState extends State<_PreviewDialog> {
  // 豆瓣 / Bangumi 加载状态
  bool _isDoubanLoading = false;
  bool _isBangumiLoading = false;
  DoubanMovieDetails? _douban;
  BangumiDetails? _bangumi;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _loadExtras();
  }

  /// v2.3.32: 自动判 Bangumi (6 位 ID) / 豆瓣
  /// 跟 web `isBangumiId = (id) => id > 0 && id.toString().length === 6` 1:1
  bool _isBangumiId(int id) => id > 0 && id.toString().length == 6;

  Future<void> _loadExtras() async {
    final dId = widget.detail.vodDoubanId;
    if (dId <= 0) {
      // 没 douban_id 就不强行拉, 跟 player_screen 行为一致
      return;
    }
    if (_isBangumiId(dId)) {
      setState(() => _isBangumiLoading = true);
      try {
        final resp = await BangumiService.getBangumiDetails(
          context,
          bangumiId: dId.toString(),
        );
        if (!mounted) return;
        if (resp.success && resp.data != null) {
          setState(() => _bangumi = resp.data);
        } else {
          setState(() => _loadError = resp.message);
        }
      } catch (e) {
        if (!mounted) return;
        setState(() => _loadError = 'Bangumi 加载失败: $e');
      } finally {
        if (mounted) setState(() => _isBangumiLoading = false);
      }
    } else {
      setState(() => _isDoubanLoading = true);
      try {
        final resp = await DoubanService.getDoubanDetails(
          context,
          doubanId: dId.toString(),
        );
        if (!mounted) return;
        if (resp.success && resp.data != null) {
          setState(() => _douban = resp.data);
        } else {
          setState(() => _loadError = resp.message);
        }
      } catch (e) {
        if (!mounted) return;
        setState(() => _loadError = '豆瓣加载失败: $e');
      } finally {
        if (mounted) setState(() => _isDoubanLoading = false);
      }
    }
  }

  Future<void> _openExternal(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = widget.detail;
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
      child: Container(
        constraints: const BoxConstraints(maxWidth: 800, maxHeight: 700),
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
              color: theme.colorScheme.outlineVariant.withOpacity(0.5)),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(theme),
            Flexible(child: _buildBody(theme)),
            _buildFooter(theme),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        border: Border(
            bottom: BorderSide(
                color: theme.colorScheme.outlineVariant.withOpacity(0.3))),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Colors.indigo, Colors.blue],
              ),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Icon(Icons.tv, color: Colors.white, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              widget.detail.title.isEmpty ? '详情预览' : widget.detail.title,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _buildBody(ThemeData theme) {
    final d = widget.detail;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 顶: 海报 + 元数据
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: SizedBox(
                  width: 110,
                  height: 160,
                  child: d.poster.isNotEmpty
                      ? CachedNetworkImage(
                          imageUrl: d.poster,
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
              Expanded(child: _buildMeta(theme)),
            ],
          ),
          const SizedBox(height: 12),
          // 评分徽章 + 外链按钮
          _buildRatingRow(theme),
          const SizedBox(height: 12),
          // 类型 / 地区 / 年份 标签
          _buildTagRow(theme),
          const SizedBox(height: 12),
          // 简介 (优先豆瓣/Bangumi, fallback 源 content)
          _buildDescription(theme),
          // 豆瓣 section
          if (_isDoubanLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('加载豆瓣信息...', style: TextStyle(fontSize: 12)),
              ]),
            )
          else if (_douban != null)
            _buildDoubanSection(theme, _douban!),
          // Bangumi section
          if (_isBangumiLoading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 8),
                Text('加载 Bangumi 信息...', style: TextStyle(fontSize: 12)),
              ]),
            )
          else if (_bangumi != null)
            _buildBangumiSection(theme, _bangumi!),
          if (_loadError != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_loadError!,
                  style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.error.withOpacity(0.7))),
            ),
        ],
      ),
    );
  }

  Widget _buildMeta(ThemeData theme) {
    final d = widget.detail;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (d.title.isNotEmpty)
          Text(d.title,
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              maxLines: 2,
              overflow: TextOverflow.ellipsis),
        const SizedBox(height: 4),
        if (d.year.isNotEmpty)
          Text('年份: ${d.year}',
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
        Text('来源: ${widget.resource.name}',
            style: TextStyle(
                fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
        if (d.director.isNotEmpty)
          Text('导演: ${d.director}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
        if (d.actor.isNotEmpty)
          Text('主演: ${d.actor}',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                  fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
      ],
    );
  }

  Widget _buildRatingRow(ThemeData theme) {
    final dId = widget.detail.vodDoubanId;
    final hasDouban = _douban != null;
    final hasBangumi = _bangumi != null;
    if (dId <= 0 && !hasDouban && !hasBangumi) {
      return const SizedBox.shrink();
    }
    return Wrap(
      spacing: 8,
      runSpacing: 6,
      children: [
        if (hasDouban && _douban!.rate != null)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.green.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text('豆瓣 ${_douban!.rate}',
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.green,
                    fontWeight: FontWeight.w600)),
          ),
        if (hasBangumi && _bangumi!.rating.score > 0)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: Colors.purple.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
                'Bangumi ${_bangumi!.rating.score.toStringAsFixed(1)}',
                style: const TextStyle(
                    fontSize: 11,
                    color: Colors.purple,
                    fontWeight: FontWeight.w600)),
          ),
        if (hasDouban && dId > 0)
          InkWell(
            onTap: () => _openExternal(
                'https://movie.douban.com/subject/$dId/'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.open_in_new, size: 12, color: Colors.blue),
                SizedBox(width: 2),
                Text(' 豆瓣',
                    style: TextStyle(fontSize: 11, color: Colors.blue)),
              ],
            ),
          ),
        if (hasBangumi && dId > 0)
          InkWell(
            onTap: () => _openExternal('https://bgm.tv/subject/$dId'),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: const [
                Icon(Icons.open_in_new, size: 12, color: Colors.purple),
                SizedBox(width: 2),
                Text(' Bangumi',
                    style: TextStyle(fontSize: 11, color: Colors.purple)),
              ],
            ),
          ),
      ],
    );
  }

  Widget _buildTagRow(ThemeData theme) {
    final d = widget.detail;
    final tags = <String>[];
    if (d.typeName.isNotEmpty) tags.add(d.typeName);
    if (d.area.isNotEmpty) tags.add(d.area);
    if (d.lang.isNotEmpty) tags.add(d.lang);
    if (_douban != null) {
      tags.addAll(_douban!.genres);
      tags.addAll(_douban!.countries);
      tags.addAll(_douban!.languages);
    }
    if (_bangumi != null) tags.addAll(_bangumi!.tags.take(5));
    final unique = <String>{};
    final list = tags.where((t) {
      final clean = t.trim();
      if (clean.isEmpty) return false;
      return unique.add(clean);
    }).toList();
    if (list.isEmpty) return const SizedBox.shrink();
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: list
          .map((t) => Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(t, style: const TextStyle(fontSize: 10)),
              ))
          .toList(),
    );
  }

  Widget _buildDescription(ThemeData theme) {
    String? desc;
    if (_douban?.summary != null && _douban!.summary!.trim().isNotEmpty) {
      desc = _douban!.summary!.trim();
    } else if (_bangumi?.summary.isNotEmpty == true) {
      desc = _bangumi!.summary.trim();
    } else if (widget.detail.remarks.isNotEmpty) {
      desc = widget.detail.remarks;
    } else if (widget.detail.content.isNotEmpty) {
      desc = _stripHtml(widget.detail.content);
    }
    if (desc == null || desc.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withOpacity(0.5),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        desc,
        style: const TextStyle(fontSize: 12, height: 1.5),
        maxLines: 8,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _buildDoubanSection(ThemeData theme, DoubanMovieDetails d) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text('豆瓣信息',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        if (d.directors.isNotEmpty)
          Text('导演: ${d.directors.join('、')}',
              style: const TextStyle(fontSize: 12)),
        if (d.screenwriters.isNotEmpty)
          Text('编剧: ${d.screenwriters.join('、')}',
              style: const TextStyle(fontSize: 12)),
        if (d.actors.isNotEmpty)
          Text('主演: ${d.actors.take(8).join('、')}${d.actors.length > 8 ? '…' : ''}',
              style: const TextStyle(fontSize: 12)),
        if (d.releaseDate != null && d.releaseDate!.isNotEmpty)
          Text('首播/上映: ${d.releaseDate}',
              style: const TextStyle(fontSize: 12)),
        if (d.totalEpisodes != null ||
            d.duration != null)
          Text(
            [
              if (d.totalEpisodes != null) '集数: ${d.totalEpisodes}',
              if (d.duration != null) '片长: ${d.duration}',
            ].join(' '),
            style: TextStyle(
                fontSize: 11, color: theme.colorScheme.onSurfaceVariant),
          ),
      ],
    );
  }

  Widget _buildBangumiSection(ThemeData theme, BangumiDetails b) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        const Text('Bangumi 信息',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        if (b.date != null && b.date!.isNotEmpty)
          Text('首播: ${b.date}', style: const TextStyle(fontSize: 12)),
        if (b.eps > 0) Text('集数: ${b.eps}', style: const TextStyle(fontSize: 12)),
        if (b.infobox.isNotEmpty) ...[
          const SizedBox(height: 4),
          ...b.infobox.take(8).map((s) => Text(s, style: const TextStyle(fontSize: 11))),
        ],
      ],
    );
  }

  Widget _buildFooter(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: BoxDecoration(
        border: Border(
            top: BorderSide(
                color: theme.colorScheme.outlineVariant.withOpacity(0.3))),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('立即播放'),
            onPressed: widget.onPlay,
            style: FilledButton.styleFrom(
              backgroundColor: Colors.teal,
              foregroundColor: Colors.white,
            ),
          ),
        ],
      ),
    );
  }

  static String _stripHtml(String html) {
    return html
        .replaceAll(RegExp(r'<[^>]*>'), '')
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&amp;', '&')
        .trim();
  }
}
