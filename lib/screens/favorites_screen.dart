import 'package:flutter/material.dart';
import 'package:luna_tv/widgets/favorites_grid.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';

class FavoritesScreen extends StatefulWidget {
  const FavoritesScreen({super.key});

  @override
  State<FavoritesScreen> createState() => _FavoritesScreenState();
}

class _FavoritesScreenState extends State<FavoritesScreen> {
  @override
  void initState() {
    super.initState();
    FavoritesGrid.refreshFavorites();
  }

  void _onVideoTap(PlayRecord playRecord) {
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (context) => PlayerScreen(
          videoInfo: VideoInfo.fromPlayRecord(playRecord),
        ),
      ),
    ).then((_) {
      // 返回时刷新收藏列表
      if (mounted) {
        FavoritesGrid.refreshFavorites();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('收藏夹'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 4),
            FavoritesGrid(
              onVideoTap: _onVideoTap,
            ),
          ],
        ),
      ),
    );
  }
}
