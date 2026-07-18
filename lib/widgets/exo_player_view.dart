// v2.2.0: 播放器 UI 桥接 widget — 替代 libmpv 时代 media_kit_video.Video.
//
// v2.3.11: 不再渲染 video_player 的 [VideoPlayer] widget (依赖
//   video_player Flutter package). 改用 Flutter [Texture] widget 渲染
//   [ExoPlayerBackend.textureId] (CustomExoPlayer 拿到的 Flutter
//   SurfaceTexture ID). 视频帧从原生 ExoPlayer 写到 SurfaceTexture,
//   走 GPU texture 0 copy 显示.
//
// UI 控件 (LunaTV 自定义底栏/顶栏/手势) 全部在 player_screen.dart 自己的
//   _buildPlayingView 里, 这个 widget 只是个薄壳, 只负责把 video 画面贴到
//   AspectRatio + Stack 上.

import 'package:flutter/material.dart';

import 'package:luna_tv/services/exo_player_backend.dart';

class ExoPlayerView extends StatelessWidget {
  final ExoPlayerBackend backend;

  const ExoPlayerView({super.key, required this.backend});

  @override
  Widget build(BuildContext context) {
    // v2.3.11: 拿到底层 Flutter SurfaceTexture textureId 渲染 [Texture]
    //   widget. 没初始化完 (player 还没 create) → 黑屏兜底, 等 ExoPlayer
    //   create 完成 / setState 触发自动 rebuild.
    final tid = backend.textureId;
    if (tid == null) {
      return const ColoredBox(color: Colors.black);
    }
    return Texture(textureId: tid);
  }
}
