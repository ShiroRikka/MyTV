// v2.2.0: 播放器 UI 桥接 widget — 替代 libmpv 时代 media_kit_video.Video.
//
// 之前: [Video(controller: VideoController(player), controls: NoVideoControls)]
// 现在: [ExoPlayerView(backend: ...)] — 内部拿 backend.rawController 渲染
// [VideoPlayer] widget (基于 AndroidX Media3 PlayerView).
//
// UI 控件 (LunaTV 自定义底栏/顶栏/手势) 全部在 player_screen.dart 自己的
// _buildPlayingView 里, 这个 widget 只是个薄壳, 只负责把 video 画面贴到
// AspectRatio + Stack 上.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'package:luna_tv/services/exo_player_backend.dart';

class ExoPlayerView extends StatelessWidget {
  final ExoPlayerBackend backend;

  const ExoPlayerView({super.key, required this.backend});

  @override
  Widget build(BuildContext context) {
    // v2.2.0: 拿到底层 VideoPlayerController 渲染 [VideoPlayer] widget.
    //   没初始化完 (controller 还没 create 出来) → 黑屏兜底, 等 listener 推
    //   stream 后自动 rebuild.
    final c = backend.rawController;
    if (c == null || !c.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return VideoPlayer(c);
  }
}
