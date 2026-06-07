import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:luna_tv/services/douban_service.dart';
import 'package:luna_tv/models/douban_movie.dart';

class DoubanDetailScreen extends StatefulWidget {
  final String id;
  final String kind;
  final String? title;
  final String? poster;

  const DoubanDetailScreen({
    super.key,
    required this.id,
    required this.kind,
    this.title,
    this.poster,
  });

  factory DoubanDetailScreen.fromArgs(BuildContext context) {
    final args = ModalRoute.of(context)?.settings.arguments as Map<String, dynamic>?;
    return DoubanDetailScreen(
      id: args?['id'] ?? '',
      kind: args?['kind'] ?? 'movie',
      title: args?['title'],
      poster: args?['poster'],
    );
  }

  @override
  State<DoubanDetailScreen> createState() => _DoubanDetailScreenState();
}

class _DoubanDetailScreenState extends State<DoubanDetailScreen> {
  late Future<ApiResponse<DoubanMovieDetails>> _future;
  DoubanMovieDetails? _details;

  @override
  void initState() {
    super.initState();
    _future = DoubanService.getDoubanDetails(widget.id, widget.kind);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            expandedHeight: 260,
            pinned: true,
            leading: const BackButton(),
            flexibleSpace: FlexibleSpaceBar(
              title: Text(widget.title ?? '豆瓣详情'),
              background: (widget.poster != null && widget.poster!.isNotEmpty)
                  ? CachedNetworkImage(
                      imageUrl: widget.poster!,
                      fit: BoxFit.cover,
                      placeholder: (c, u) => Container(color: Colors.grey.shade300),
                      errorWidget: (c, u, e) => Container(color: Colors.grey.shade300),
                    )
                  : Container(color: Colors.grey.shade300),
            ),
          ),
          SliverToBoxAdapter(
            child: FutureBuilder<ApiResponse<DoubanMovieDetails>>(
              future: _future,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Padding(
                    padding: EdgeInsets.all(24),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                final resp = snapshot.data;
                if (resp == null || resp.error != null) {
                  return Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text('加载失败：${resp?.error ?? "未知错误"}', style: const TextStyle(color: Colors.red)),
                  );
                }
                final d = resp.data!;
                _details = d;
                final rateText = (d.rate?.isNotEmpty == true) ? d.rate! : '暂无评分';
                final year = d.year.isNotEmpty ? d.year : '';
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (d.poster != null && d.poster!.isNotEmpty)
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: CachedNetworkImage(
                                imageUrl: d.poster!,
                                width: 100,
                                height: 150,
                                fit: BoxFit.cover,
                                placeholder: (c, u) => Container(width: 100, height: 150, color: Colors.grey.shade300),
                                errorWidget: (c, u, e) => Container(width: 100, height: 150, color: Colors.grey.shade300),
                              ),
                            ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(d.title, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600)),
                                if (year.isNotEmpty) ...[
                                  const SizedBox(height: 6),
                                  Text(year, style: const TextStyle(fontSize: 13, color: Colors.black54)),
                                ],
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    const Icon(Icons.star, size: 16, color: Colors.orange),
                                    const SizedBox(width: 4),
                                    Text(rateText, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w500)),
                                  ],
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 6,
                                  children: [
                                    ...d.genres.map((g) => Chip(label: Text(g), visualDensity: VisualDensity.compact, padding: EdgeInsets.zero)),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const Divider(height: 32),
                      if (d.directors.isNotEmpty) ...[
                        _buildRow('导演', d.directors.join(' / ')),
                      ],
                      if (d.screenwriters.isNotEmpty) ...[
                        _buildRow('编剧', d.screenwriters.join(' / ')),
                      ],
                      if (d.actors.isNotEmpty) ...[
                        _buildRow('主演', d.actors.join(' / ')),
                      ],
                      if (d.countries.isNotEmpty) ...[
                        _buildRow('国家/地区', d.countries.join(' / ')),
                      ],
                      if (d.languages.isNotEmpty) ...[
                        _buildRow('语言', d.languages.join(' / ')),
                      ],
                      if (d.releaseDate != null && d.releaseDate!.isNotEmpty) ...[
                        _buildRow('上映', d.releaseDate!),
                      ],
                      if (d.duration != null && d.duration!.isNotEmpty) ...[
                        _buildRow('片长', d.duration!),
                      ],
                      if (d.summary != null && d.summary!.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text('简介', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                        const SizedBox(height: 8),
                        Text(d.summary!, style: const TextStyle(fontSize: 14, height: 1.5)),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(label, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500)),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 14, height: 1.4))),
        ],
      ),
    );
  }
}
