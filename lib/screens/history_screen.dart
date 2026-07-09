import 'package:flutter/material.dart';
import 'package:luna_tv/widgets/history_grid.dart';
import 'package:luna_tv/models/play_record.dart';
import 'package:luna_tv/models/video_info.dart';
import 'package:luna_tv/screens/player_screen.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  @override
  void initState() {
    super.initState();
    HistoryGrid.refreshHistory();
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
      // 返回时刷新历史列表
      if (mounted) {
        HistoryGrid.refreshHistory();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('播放历史'),
      ),
      body: SingleChildScrollView(
        child: Column(
          children: [
            const SizedBox(height: 4),
            HistoryGrid(
              onVideoTap: _onVideoTap,
            ),
          ],
        ),
      ),
    );
  }
}
