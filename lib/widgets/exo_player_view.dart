// v2.2.0: 播放器 UI 桥接 widget — 替代 libmpv 时代 media_kit_video.Video.
//
// v2.3.14: 走 Flutter 官方 [video_player] package 的 [VideoPlayer] widget,
//   渲染 [ExoPlayerBackend.controller] (VideoPlayerController) 给的视频帧.
//   v2.3.11 ~ v2.3.13 改用自研 CustomExoPlayer + Flutter Texture widget
//   (走 ExoPlayer SurfaceTexture 输出), v2.3.14 卸自研 CustomExoPlayer 后
//   回到 v2.3.0 的 VideoPlayer 渲染路径.
//
// UI 控件 (LunaTV 自定义底栏/顶栏/手势) 全部在 player_screen.dart 自己的
//   _buildPlayingView 里, 这个 widget 只是个薄壳, 只负责把 video 画面贴到
//   AspectRatio + Stack 上.

import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

import 'package:luna_tv/services/exo_player_backend.dart';

class ExoPlayerView extends StatelessWidget {
  final ExoPlayerBackend backend;

  const ExoPlayerView({super.key, required this.backend});

  @override
  Widget build(BuildContext context) {
    // v2.3.14: 拿到底层 VideoPlayerController 渲染 [VideoPlayer] widget.
    //   没初始化完 (controller 还没 build) → 黑屏兜底, 等 ExoPlayerBackend.open
    //   完成后 (controller != null) 触发 rebuild 自动出画面.
    final controller = backend.controller;
    if (controller == null || !controller.value.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }
    return Center(
      child: AspectRatio(
        aspectRatio: controller.value.aspectRatio,
        child: VideoPlayer(controller),
      ),
    );
  }
}
