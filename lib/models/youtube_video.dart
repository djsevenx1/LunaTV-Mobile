/// YouTube 视频数据模型
class YouTubeVideo {
  final String id;
  final String title;
  final String thumbnail;
  final String channelTitle;
  final String duration;
  final int viewCount;
  final String publishedAt;

  const YouTubeVideo({
    required this.id,
    required this.title,
    required this.thumbnail,
    required this.channelTitle,
    required this.duration,
    required this.viewCount,
    required this.publishedAt,
  });

  factory YouTubeVideo.fromJson(Map<String, dynamic> json) {
    return YouTubeVideo(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      thumbnail: json['thumbnail']?.toString() ?? '',
      channelTitle: json['channel_title']?.toString() ?? '',
      duration: json['duration']?.toString() ?? '',
      viewCount: json['view_count'] is int
          ? json['view_count']
          : int.tryParse(json['view_count']?.toString() ?? '0') ?? 0,
      publishedAt: json['published_at']?.toString() ?? '',
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'thumbnail': thumbnail,
      'channel_title': channelTitle,
      'duration': duration,
      'view_count': viewCount,
      'published_at': publishedAt,
    };
  }
}
