class MediaItem {
  final String id;
  final String title;
  final String? subtitle;
  final int year;
  final String cover;
  final double rating;
  final String? director;
  final String? cast;
  final String? duration;
  final String? quality;
  final String type; // 'movie', 'tv', 'shortdrama', 'live'
  final String? source;

  const MediaItem({
    required this.id,
    required this.title,
    this.subtitle,
    required this.year,
    required this.cover,
    this.rating = 0.0,
    this.director,
    this.cast,
    this.duration,
    this.quality,
    required this.type,
    this.source,
  });
}
