import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import 'dart:io' show Platform;
import 'dart:ui' as ui;
import 'package:luna_tv/services/api_service.dart';
import 'package:luna_tv/services/search_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:luna_tv/utils/font_utils.dart';
import 'package:luna_tv/widgets/user_menu.dart';

class MainLayout extends StatefulWidget {
  final Widget content;
  final int currentBottomNavIndex;
  final Function(int) onBottomNavChanged;
  final String selectedTopTab;
  final Function(String) onTopTabChanged;
  final bool isSearchMode;
  final VoidCallback? onSearchTap;
  final VoidCallback? onHomeTap;
  final TextEditingController? searchController;
  final FocusNode? searchFocusNode;
  final String? searchQuery;
  final Function(String)? onSearchQueryChanged;
  final Function(String)? onSearchSubmitted;
  final VoidCallback? onClearSearch;
  final bool showBottomNav;

  const MainLayout({
    super.key,
    required this.content,
    required this.currentBottomNavIndex,
    required this.onBottomNavChanged,
    required this.selectedTopTab,
    required this.onTopTabChanged,
    this.isSearchMode = false,
    this.onSearchTap,
    this.onHomeTap,
    this.searchController,
    this.searchFocusNode,
    this.searchQuery,
    this.onSearchQueryChanged,
    this.onSearchSubmitted,
    this.onClearSearch,
    this.showBottomNav = true,
  });

  @override
  State<MainLayout> createState() => _MainLayoutState();
}

class _MainLayoutState extends State<MainLayout> {
  bool _isSearchButtonPressed = false;

  // 用于跟踪底部导航栏按钮的 hover 状态
  int? _hoveredNavIndex;

  // 用于跟踪搜索按钮的 hover 状态
  bool _isSearchButtonHovered = false;

  // 用于跟踪主题切换按钮的 hover 状态
  bool _isThemeButtonHovered = false;

  // 用于跟踪用户按钮的 hover 状态
  bool _isUserButtonHovered = false;

  // 用于跟踪返回按钮的 hover 状态
  bool _isBackButtonHovered = false;

  // 用于跟踪搜索框内清除按钮的 hover 状态
  bool _isClearButtonHovered = false;

  // 用于跟踪搜索框内搜索按钮的 hover 状态
  bool _isSearchSubmitButtonHovered = false;

  // 搜索建议相关状态
  List<String> _searchSuggestions = [];
  Timer? _debounceTimer;
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _removeOverlay();
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _fetchSearchSuggestions(String query) async {
    if (query.trim().isEmpty) {
      if (mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            setState(() {
              _searchSuggestions = [];
            });
            _removeOverlay();
          }
        });
      }
      return;
    }

    final currentQuery = query;
    final isLocalMode = await UserDataService.getIsLocalMode();
    final isLocalSearch = await UserDataService.getLocalSearch();

    List<String> suggestionResults;
    if (isLocalMode || isLocalSearch) {
      suggestionResults = await SearchService.searchRecommand(query.trim());
    } else {
      suggestionResults = await ApiService.getSearchSuggestions(query.trim());
    }

    // 检查搜索框内容是否已变化
    if (!mounted ||
        widget.searchQuery != currentQuery ||
        suggestionResults.isEmpty) {
      return;
    }

    // 使用 post-frame callback 确保在正确的时机更新状态
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || widget.searchQuery != currentQuery) {
        return;
      }

      if (suggestionResults.isNotEmpty) {
        setState(() {
          _searchSuggestions = suggestionResults.take(8).toList();
        });
        // 再次使用 post-frame callback 显示 overlay
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _searchSuggestions.isNotEmpty) {
            _showSuggestionsOverlay();
          }
        });
      } else {
        setState(() {
          _searchSuggestions = [];
        });
        _removeOverlay();
      }
    });
  }

  void _onSearchQueryChanged(String query) {
    // 使用 post-frame callback 来调用父组件回调，避免在 build 期间触发 setState
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      widget.onSearchQueryChanged?.call(query);
    });

    // 取消之前的防抖计时器
    _debounceTimer?.cancel();

    if (query.trim().isEmpty) {
      // 使用 post-frame callback 来清除建议
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          setState(() {
            _searchSuggestions = [];
          });
          _removeOverlay();
        }
      });
      return;
    }

    // 设置新的防抖计时器（500ms）
    _debounceTimer = Timer(const Duration(milliseconds: 500), () {
      if (mounted && query == widget.searchQuery) {
        _fetchSearchSuggestions(query);
      }
    });
  }

  void _showSuggestionsOverlay() {
    _removeOverlay();

    if (_searchSuggestions.isEmpty) {
      return;
    }

    final themeService = Provider.of<ThemeService>(context, listen: false);
    final isTablet = DeviceUtils.isTablet(context);

    // 计算建议框宽度
    // 平板模式：屏幕宽度的 50%
    // 移动端：屏幕宽度 - 左右padding(32) - 右侧按钮宽度(32*2) - 按钮间距(12) - 按钮与搜索框间距(16)
    final screenWidth = MediaQuery.of(context).size.width;
    final suggestionWidth =
        isTablet ? screenWidth * 0.5 : screenWidth - 32 - 16 - 32 - 12 - 32;

    _overlayEntry = OverlayEntry(
      builder: (context) => Positioned(
        width: suggestionWidth,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 42), // 紧贴搜索框
          child: Material(
            elevation: 8,
            borderRadius: BorderRadius.circular(12),
            color: themeService.isDarkMode
                ? const Color(0xFF1e1e1e)
                : Colors.white,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(vertical: 4),
                shrinkWrap: true,
                itemCount: _searchSuggestions.length,
                itemBuilder: (context, index) {
                  final suggestion = _searchSuggestions[index];
                  return InkWell(
                    onTap: () {
                      widget.searchController?.text = suggestion;
                      widget.onSearchSubmitted?.call(suggestion);
                      _removeOverlay();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            LucideIcons.search,
                            size: 16,
                            color: themeService.isDarkMode
                                ? const Color(0xFF666666)
                                : const Color(0xFF95a5a6),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              suggestion,
                              style: FontUtils.poppins(context,
                                                                fontSize: 14,
                                color: themeService.isDarkMode
                                    ? const Color(0xFFffffff)
                                    : const Color(0xFF2c3e50),
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<ThemeService>(
      builder: (context, themeService, child) {
        return Theme(
          data: themeService.isDarkMode
              ? themeService.darkTheme
              : themeService.lightTheme,
          child: Scaffold(
            backgroundColor: themeService.isDarkMode
                ? const Color(0xFF000000)
                : Colors.transparent,
            resizeToAvoidBottomInset: !widget.isSearchMode,
            // v2.5.11: Android / iOS 用 SafeArea(top: true, bottom: false)
            //   替代手算顶部 padding. 之前 v2.5.10 用 `max(40, viewPadding.top) + 8`
            //   在某些 Android 设备 (Android 13+/15+, 特定 ROM) 仍被状态栏
            //   挡, 因为 `MediaQuery.padding.top` 和 `viewPadding.top` 都
            //   返回 0 (Android 13+ 透明状态栏 + Flutter view flags 不匹配).
            //   SafeArea 会从系统 WindowInsets 拿真实状态栏高度, 不依赖
            //   MediaQuery. 跨设备 / 跨 ROM / 异形屏 / 灵动岛 都能正确避开.
            //   bottom: false — 底部 nav 已经有 MediaQuery.padding.bottom 处理.
            //
            //   桌面平台 (macOS / Windows / Linux) 没手机状态栏, 仍走
            //   _buildHeader 内部按平台分支手算 (Windows 8dp 自定义标题栏,
            //   macOS mediaTop + 32 透明标题栏). 所以 SafeArea 只对移动端
            //   生效: 用 `!Platform.isAndroid && !Platform.isIOS` 时不包
            //   SafeArea, 让桌面走原路径; 反之包 SafeArea + topPaddingOverride
            //   = 0.0 让 _buildHeader 顶部 padding 由 SafeArea 负责.
            body: _buildScaffoldBody(context, themeService),
          ),
        );
      },
    );
  }

  Widget _buildScaffoldBody(BuildContext context, ThemeService themeService) {
    // 移动端 (Android / iOS): 用 SafeArea(top: true) 拿真实状态栏
    // 高度. SafeArea 从 WindowInsets 拿值, 不依赖 MediaQuery.padding.top
    // / viewPadding.top (这俩在某些 Android 13+ 透明状态栏设备返回 0).
    // header 用 topPaddingOverride: 0.0, 不再加自己的 top padding.
    //
    // 桌面端 (macOS / Windows / Linux): 没手机状态栏, 不包 SafeArea,
    // 让 _buildHeader 走原平台分支手算 (Windows 8dp / macOS 透明标题栏).
    final isMobile = Platform.isAndroid || Platform.isIOS;

    final inner = Container(
      decoration: BoxDecoration(
        color: themeService.isDarkMode
            ? const Color(0xFF000000)
            : null,
        gradient: themeService.isDarkMode
            ? null
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  Color(0xFFe6f3fb),
                  Color(0xFFeaf3f7),
                  Color(0xFFf7f7f3),
                  Color(0xFFe9ecef),
                  Color(0xFFdbe3ea),
                  Color(0xFFd3dde6),
                ],
                stops: [0.0, 0.18, 0.38, 0.60, 0.80, 1.0],
              ),
      ),
      child: Stack(
        children: [
          Column(
            children: [
              _buildHeader(
                context,
                themeService,
                // 移动端由 SafeArea 负责顶部, header 自己不再加 padding
                topPaddingOverride: isMobile ? 0.0 : null,
              ),
              Expanded(child: widget.content),
              if (widget.showBottomNav) _buildBottomNavBar(themeService),
            ],
          ),
        ],
      ),
    );

    if (isMobile) {
      return SafeArea(
        top: true,
        bottom: false,
        child: inner,
      );
    }
    return inner;
  }

  Widget _buildHeader(
      BuildContext context, ThemeService themeService,
      {double? topPaddingOverride}) {
    final isTablet = DeviceUtils.isTablet(context);

    // macOS 下需要额外的顶部 padding 来避免与透明标题栏重叠
    // Windows 下不需要额外 padding，因为自定义标题栏已经占据了空间
    //
    // v2.5.11: 整 Scaffold body 用 SafeArea(top: true, bottom: false)
    //   包住, topPaddingOverride = 0.0 让 _buildHeader 顶部 padding 由
    //   SafeArea 处理. Windows 上 SafeArea 也包, 但 Windows 在桌面上
    //   没有系统状态栏, SafeArea 自动给 0, 仍是 0. macOS 走 macOS
    //   分支 (mediaTop + 32), 用 viewPadding.top (含 macOS 透明标题栏
    //   32dp). 旧 v2.5.9 / v2.5.10 手动算 `max(padding.top, 24/40) + 8`
    //   在某些 Android 15 / 异形屏 上 padding.top / viewPadding.top
    //   都返回 0, 失效.
    final mediaQuery = MediaQuery.of(context);
    final mediaTop = mediaQuery.padding.top;
    final viewTop = mediaQuery.viewPadding.top;
    final double topPadding;
    if (topPaddingOverride != null) {
      // 调用方已用 SafeArea 处理了顶部, header 不再加 padding
      topPadding = topPaddingOverride;
    } else if (DeviceUtils.isMacOS()) {
      topPadding = mediaTop + 32;
    } else if (Platform.isWindows) {
      topPadding = 8.0;
    } else {
      // Android / iOS 兜底路径 (实际不会走, 因为上面 SafeArea 已处理)
      final baseTop = viewTop > mediaTop ? viewTop : mediaTop;
      final safeTop = baseTop < 40.0 ? 40.0 : baseTop;
      topPadding = safeTop + 8;
    }

    return Container(
      padding: EdgeInsets.only(
        top: topPadding,
        left: 16,
        right: 16,
        bottom: 8,
      ),
      decoration: BoxDecoration(
        color: widget.isSearchMode
            ? themeService.isDarkMode
                ? const Color(0xFF121212)
                : const Color(0xFFf5f5f5)
            : themeService.isDarkMode
                ? const Color(0xFF1e1e1e).withOpacity(0.9)
                : Colors.white.withOpacity(0.8),
      ),
      child: widget.isSearchMode
          ? _buildSearchHeader(context, themeService, isTablet)
          : _buildNormalHeader(context, themeService),
    );
  }

  Widget _buildNormalHeader(BuildContext context, ThemeService themeService) {
    return SizedBox(
      height: 40, // 固定高度，与搜索框高度一致
      child: Stack(
        children: [
          // 左侧搜索图标
          Positioned(
            left: 0,
            top: 4,
            child: MouseRegion(
              cursor: DeviceUtils.isPC()
                  ? SystemMouseCursors.click
                  : MouseCursor.defer,
              onEnter: DeviceUtils.isPC()
                  ? (_) {
                      setState(() {
                        _isSearchButtonHovered = true;
                      });
                    }
                  : null,
              onExit: DeviceUtils.isPC()
                  ? (_) {
                      setState(() {
                        _isSearchButtonHovered = false;
                      });
                    }
                  : null,
              child: GestureDetector(
                onTap: () {
                  // 防止重复点击
                  if (_isSearchButtonPressed) return;

                  setState(() {
                    _isSearchButtonPressed = true;
                  });

                  widget.onSearchTap?.call();

                  // 延迟重置按钮状态，防止快速重复点击
                  Future.delayed(const Duration(milliseconds: 300), () {
                    if (mounted) {
                      setState(() {
                        _isSearchButtonPressed = false;
                      });
                    }
                  });
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: DeviceUtils.isPC() && _isSearchButtonHovered
                        ? (themeService.isDarkMode
                            ? const Color(0xFF333333)
                            : const Color(0xFFe0e0e0))
                        : Colors.transparent,
                  ),
                  child: Center(
                    child: Icon(
                      LucideIcons.search,
                      color: themeService.isDarkMode
                          ? const Color(0xFFffffff)
                          : const Color(0xFF2c3e50),
                      size: 24,
                      weight: 1.0,
                    ),
                  ),
                ),
              ),
            ),
          ),
          // 完全居中的 Logo
          Center(
            child: GestureDetector(
              onTap: widget.onHomeTap,
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF3B82F6), Color(0xFF9333EA)],
                      ),
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: const Icon(Icons.tv, color: Colors.white, size: 18),
                  ),
                  const SizedBox(width: 8),
                  ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      colors: [Color(0xFF2563EB), Color(0xFF9333EA)],
                    ).createShader(bounds),
                    child: const Text(
                      'LunaTV',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // 右侧按钮组
          Positioned(
            right: 0,
            top: 4,
            child: _buildRightButtons(themeService),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchHeader(
      BuildContext context, ThemeService themeService, bool isTablet) {
    final searchBoxWidget = CompositedTransformTarget(
      link: _layerLink,
      child: Container(
        decoration: BoxDecoration(
          color:
              themeService.isDarkMode ? const Color(0xFF1e1e1e) : Colors.white,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Focus(
          onFocusChange: (hasFocus) {
            if (!hasFocus) {
              // 失焦时关闭建议框
              _removeOverlay();
            }
          },
          child: TextField(
            controller: widget.searchController,
            focusNode: widget.searchFocusNode,
            autofocus: false,
            textInputAction: TextInputAction.search,
            keyboardType: TextInputType.text,
            textAlignVertical: TextAlignVertical.center,
            decoration: InputDecoration(
              hintText: '搜索电影、剧集、动漫...',
              hintStyle: FontUtils.poppins(context,
                                color: themeService.isDarkMode
                    ? const Color(0xFF666666)
                    : const Color(0xFF95a5a6),
                fontSize: 14,
              ),
              suffixIcon: SizedBox(
                width: isTablet ? 80 : 80, // 固定宽度确保按钮位置一致
                child: Stack(
                  alignment: Alignment.centerRight,
                  children: [
                    // 搜索按钮 - 固定在右侧
                    Positioned(
                      right: isTablet ? 8 : 12,
                      child: MouseRegion(
                        cursor:
                            (widget.searchQuery?.trim().isNotEmpty ?? false) &&
                                    DeviceUtils.isPC()
                                ? SystemMouseCursors.click
                                : MouseCursor.defer,
                        onEnter: DeviceUtils.isPC() &&
                                (widget.searchQuery?.trim().isNotEmpty ?? false)
                            ? (_) {
                                setState(() {
                                  _isSearchSubmitButtonHovered = true;
                                });
                              }
                            : null,
                        onExit: DeviceUtils.isPC() &&
                                (widget.searchQuery?.trim().isNotEmpty ?? false)
                            ? (_) {
                                setState(() {
                                  _isSearchSubmitButtonHovered = false;
                                });
                              }
                            : null,
                        child: GestureDetector(
                          onTap:
                              (widget.searchQuery?.trim().isNotEmpty ?? false)
                                  ? () {
                                      _removeOverlay();
                                      widget.onSearchSubmitted
                                          ?.call(widget.searchQuery!);
                                    }
                                  : null,
                          behavior: HitTestBehavior.opaque,
                          child: Container(
                            padding: EdgeInsets.all(isTablet ? 6 : 8),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: DeviceUtils.isPC() &&
                                      _isSearchSubmitButtonHovered &&
                                      (widget.searchQuery?.trim().isNotEmpty ??
                                          false)
                                  ? (themeService.isDarkMode
                                      ? const Color(0xFF333333)
                                      : const Color(0xFFe0e0e0))
                                  : Colors.transparent,
                            ),
                            child: Icon(
                              LucideIcons.search,
                              color: (widget.searchQuery?.trim().isNotEmpty ??
                                      false)
                                  ? const Color(0xFF27ae60)
                                  : themeService.isDarkMode
                                      ? const Color(0xFFb0b0b0)
                                      : const Color(0xFF7f8c8d),
                              size: isTablet ? 18 : 16,
                            ),
                          ),
                        ),
                      ),
                    ),
                    // 清除按钮 - 在搜索按钮左侧（仅在有内容时显示）
                    Positioned(
                      right: isTablet ? 42 : 44,
                      child: Visibility(
                        visible: widget.searchQuery?.isNotEmpty ?? false,
                        maintainSize: true,
                        maintainAnimation: true,
                        maintainState: true,
                        child: MouseRegion(
                          cursor: DeviceUtils.isPC()
                              ? SystemMouseCursors.click
                              : MouseCursor.defer,
                          onEnter: DeviceUtils.isPC()
                              ? (_) {
                                  setState(() {
                                    _isClearButtonHovered = true;
                                  });
                                }
                              : null,
                          onExit: DeviceUtils.isPC()
                              ? (_) {
                                  setState(() {
                                    _isClearButtonHovered = false;
                                  });
                                }
                              : null,
                          child: GestureDetector(
                            onTap: () {
                              _removeOverlay();
                              widget.onClearSearch?.call();
                            },
                            behavior: HitTestBehavior.opaque,
                            child: Container(
                              padding: EdgeInsets.all(isTablet ? 6 : 8),
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color:
                                    DeviceUtils.isPC() && _isClearButtonHovered
                                        ? (themeService.isDarkMode
                                            ? const Color(0xFF333333)
                                            : const Color(0xFFe0e0e0))
                                        : Colors.transparent,
                              ),
                              child: Icon(
                                LucideIcons.x,
                                color: themeService.isDarkMode
                                    ? const Color(0xFFb0b0b0)
                                    : const Color(0xFF7f8c8d),
                                size: isTablet ? 18 : 16,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 6,
              ),
              isDense: true,
            ),
            style: FontUtils.poppins(context,
                            fontSize: 14,
              color: themeService.isDarkMode
                  ? const Color(0xFFffffff)
                  : const Color(0xFF2c3e50),
            ).copyWith(height: 1.2),
            onSubmitted: (value) {
              _removeOverlay();
              widget.onSearchSubmitted?.call(value);
            },
            onChanged: _onSearchQueryChanged,
            onTap: () {
              // 聚焦时如果有内容，显示建议
              if (widget.searchQuery?.trim().isNotEmpty ?? false) {
                _fetchSearchSuggestions(widget.searchQuery!);
              }
            },
          ),
        ),
      ),
    );

    // 平板模式下居中
    if (isTablet) {
      return SizedBox(
        height: 40, // 固定高度
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 左侧返回按钮
            Positioned(
              left: 0,
              child: MouseRegion(
                cursor: DeviceUtils.isPC()
                    ? SystemMouseCursors.click
                    : MouseCursor.defer,
                onEnter: DeviceUtils.isPC()
                    ? (_) {
                        setState(() {
                          _isBackButtonHovered = true;
                        });
                      }
                    : null,
                onExit: DeviceUtils.isPC()
                    ? (_) {
                        setState(() {
                          _isBackButtonHovered = false;
                        });
                      }
                    : null,
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                  },
                  behavior: HitTestBehavior.opaque,
                  child: Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: DeviceUtils.isPC() && _isBackButtonHovered
                          ? (themeService.isDarkMode
                              ? const Color(0xFF333333)
                              : const Color(0xFFe0e0e0))
                          : Colors.transparent,
                    ),
                    child: Center(
                      child: Icon(
                        LucideIcons.arrowLeft,
                        color: themeService.isDarkMode
                            ? const Color(0xFFffffff)
                            : const Color(0xFF2c3e50),
                        size: 24,
                        weight: 1.0,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            // 搜索框在整个屏幕水平居中
            Center(
              child: SizedBox(
                width: MediaQuery.of(context).size.width * 0.5,
                child: searchBoxWidget,
              ),
            ),
            // 右侧按钮 - 垂直居中
            Positioned(
              right: 0,
              child: _buildRightButtons(themeService),
            ),
          ],
        ),
      );
    }

    // 非平板模式下，搜索框居左，右侧留出按钮空间
    return SizedBox(
      height: 40, // 固定高度
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(child: searchBoxWidget),
          const SizedBox(width: 16),
          _buildRightButtons(themeService),
        ],
      ),
    );
  }

  Widget _buildRightButtons(ThemeService themeService) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 深浅模式切换按钮
        MouseRegion(
          cursor:
              DeviceUtils.isPC() ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isThemeButtonHovered = true;
                  });
                }
              : null,
          onExit: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isThemeButtonHovered = false;
                  });
                }
              : null,
          child: GestureDetector(
            onTap: () {
              themeService.toggleTheme();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: DeviceUtils.isPC() && _isThemeButtonHovered
                    ? (themeService.isDarkMode
                        ? const Color(0xFF333333)
                        : const Color(0xFFe0e0e0))
                    : Colors.transparent,
              ),
              child: Center(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder:
                      (Widget child, Animation<double> animation) {
                    return ScaleTransition(
                      scale: animation,
                      child: child,
                    );
                  },
                  child: Icon(
                    themeService.isDarkMode
                        ? LucideIcons.sun
                        : LucideIcons.moon,
                    key: ValueKey(themeService.isDarkMode),
                    color: themeService.isDarkMode
                        ? const Color(0xFFffffff)
                        : const Color(0xFF2c3e50),
                    size: 24,
                    weight: 1.0,
                  ),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        // 用户按钮
        MouseRegion(
          cursor:
              DeviceUtils.isPC() ? SystemMouseCursors.click : MouseCursor.defer,
          onEnter: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isUserButtonHovered = true;
                  });
                }
              : null,
          onExit: DeviceUtils.isPC()
              ? (_) {
                  setState(() {
                    _isUserButtonHovered = false;
                  });
                }
              : null,
          child: GestureDetector(
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => UserMenu(
                    isDarkMode: themeService.isDarkMode,
                  ),
                ),
              );
            },
            behavior: HitTestBehavior.opaque,
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: DeviceUtils.isPC() && _isUserButtonHovered
                    ? (themeService.isDarkMode
                        ? const Color(0xFF333333)
                        : const Color(0xFFe0e0e0))
                    : Colors.transparent,
              ),
              child: Center(
                child: Icon(
                  LucideIcons.user,
                  color: themeService.isDarkMode
                      ? const Color(0xFFffffff)
                      : const Color(0xFF2c3e50),
                  size: 24,
                  weight: 1.0,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBottomNavBar(ThemeService themeService) {
    final List<Map<String, dynamic>> navItems = [
      {'icon': LucideIcons.house, 'label': '首页'},
      {'icon': LucideIcons.video, 'label': '电影'},
      {'icon': LucideIcons.tv, 'label': '剧集'},
      {'icon': LucideIcons.cat, 'label': '动漫'},
      {'icon': LucideIcons.clapperboard, 'label': '短剧'},
      {'icon': LucideIcons.clover, 'label': '综艺'},
    ];

    final isTablet = DeviceUtils.isTablet(context);
    final isPC = DeviceUtils.isPC();

    // 毛玻璃背景：半透明色 + 高斯模糊
    final glassColor = themeService.isDarkMode
        ? Colors.black.withOpacity(0.45)
        : Colors.white.withOpacity(0.55);
    final borderColor = themeService.isDarkMode
        ? Colors.white.withOpacity(0.12)
        : Colors.black.withOpacity(0.08);

    // 药丸式外壳（圆角大、悬浮感）
    final pill = ClipRRect(
      borderRadius: BorderRadius.circular(28),
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 30, sigmaY: 30),
        child: Container(
          decoration: BoxDecoration(
            color: glassColor,
            border: Border.all(color: borderColor, width: 0.5),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.12),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics: const BouncingScrollPhysics(),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(navItems.length, (index) {
                final item = navItems[index];
                final isSelected =
                    !widget.isSearchMode &&
                        widget.currentBottomNavIndex == index;
                final isHovered = isPC && _hoveredNavIndex == index;

                return _buildPillTab(
                  item: item,
                  index: index,
                  isSelected: isSelected,
                  isHovered: isHovered,
                  isPC: isPC,
                  isTablet: isTablet,
                  themeService: themeService,
                );
              }),
            ),
          ),
        ),
      ),
    );

    // 平板/PC 居中显示，手机撑满大部分宽度
    if (isTablet) {
      return Padding(
        padding: EdgeInsets.only(
          left: 24,
          right: 24,
          top: 4,
          bottom: MediaQuery.of(context).padding.bottom + 10,
        ),
        child: Center(child: pill),
      );
    }

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 4,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      child: pill,
    );
  }

  /// 单个药丸 Tab：选中态显示 icon+文字(绿色背景)，未选中只显示 icon
  Widget _buildPillTab({
    required Map<String, dynamic> item,
    required int index,
    required bool isSelected,
    required bool isHovered,
    required bool isPC,
    required bool isTablet,
    required ThemeService themeService,
  }) {
    return MouseRegion(
      cursor: isPC ? SystemMouseCursors.click : MouseCursor.defer,
      onEnter: isPC
          ? (_) => setState(() => _hoveredNavIndex = index)
          : null,
      onExit: isPC
          ? (_) => setState(() => _hoveredNavIndex = null)
          : null,
      child: GestureDetector(
        onTap: () => widget.onBottomNavChanged(index),
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          padding: EdgeInsets.symmetric(
            horizontal: isSelected ? 14 : 10,
            vertical: 8,
          ),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF27ae60)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                item['icon'],
                size: 22,
                color: isSelected
                    ? Colors.white
                    : isHovered
                        ? const Color(0xFF52c77a)
                        : themeService.isDarkMode
                            ? const Color(0xFFb0b0b0)
                            : const Color(0xFF7f8c8d),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                child: isSelected
                    ? Padding(
                        padding: const EdgeInsets.only(left: 6),
                        child: Text(
                          item['label'],
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: Colors.white,
                          ),
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
            ],
          ),
        ),
      ),
    );
  }
}