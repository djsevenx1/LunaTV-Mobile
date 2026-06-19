/// Bilibili 视频数据模型
class BilibiliVideo {
  final String id;
  final String title;
  final String thumbnail;
  final String author;
  final String duration;
  final int playCount;
  final String publishedAt;

  const BilibiliVideo({
    required this.id,
    required this.title,
    required this.thumbnail,
    required this.author,
    required this.duration,
    required this.playCount,
    required this.publishedAt,
  });

  factory BilibiliVideo.fromJson(Map<String, dynamic> json) {
    return BilibiliVideo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      thumbnail: json['thumbnail']?.toString() ?? '',
      author: json['author']?.toString() ?? '',
      duration: json['duration']?.toString() ?? '',
      playCount: json['play_count'] is int
          ? json['play_count']
          : int.tryParse(json['play_count']?.toString() ?? '0') ?? 0,
      publishedAt: json['published_at']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'thumbnail': thumbnail,
      'author': author,
      'duration': duration,
      'play_count': playCount,
      'published_at': publishedAt,
    };
  }
}
