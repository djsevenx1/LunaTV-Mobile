class EpgProgram {
  final String channelId;
  final String title;
  final DateTime startTime;
  final DateTime endTime;
  final String? description;

  EpgProgram({
    required this.channelId,
    required this.title,
    required this.startTime,
    required this.endTime,
    this.description,
  });

  bool get isLive {
    final now = DateTime.now();
    return now.isAfter(startTime) && now.isBefore(endTime);
  }

  double get progress {
    final now = DateTime.now();
    if (now.isBefore(startTime)) return 0.0;
    if (now.isAfter(endTime)) return 1.0;

    final total = endTime.difference(startTime).inSeconds;
    final elapsed = now.difference(startTime).inSeconds;
    return elapsed / total;
  }

  String get timeRange {
    final start =
        '${startTime.hour.toString().padLeft(2, '0')}:${startTime.minute.toString().padLeft(2, '0')}';
    final end =
        '${endTime.hour.toString().padLeft(2, '0')}:${endTime.minute.toString().padLeft(2, '0')}';
    return '$start - $end';
  }

  factory EpgProgram.fromXml(Map<String, dynamic> data) {
    return EpgProgram(
      channelId: data['channel'] ?? '',
      title: data['title'] ?? '',
      startTime: DateTime.parse(data['start']),
      endTime: DateTime.parse(data['stop']),
      description: data['desc'],
    );
  }

  /// 从 API 返回的节目数据创建 EpgProgram
  factory EpgProgram.fromApiJson(
      Map<String, dynamic> json, String channelId) {
    return EpgProgram(
      channelId: channelId,
      title: json['title'] as String? ?? '',
      startTime: _parseDateTime(json['start'] as String? ?? ''),
      endTime: _parseDateTime(json['end'] as String? ?? ''),
      description: json['description'] as String?,
    );
  }

  /// 解析时间格式 "20251021235000 +0900"
  static DateTime _parseDateTime(String dateTimeStr) {
    if (dateTimeStr.isEmpty) return DateTime.now();

    try {
      // 格式: "20251021235000 +0900"
      final parts = dateTimeStr.split(' ');
      if (parts.isEmpty) return DateTime.now();

      final dateTimePart = parts[0];
      // 解析: YYYYMMDDHHMMSS
      final year = int.parse(dateTimePart.substring(0, 4));
      final month = int.parse(dateTimePart.substring(4, 6));
      final day = int.parse(dateTimePart.substring(6, 8));
      final hour = int.parse(dateTimePart.substring(8, 10));
      final minute = int.parse(dateTimePart.substring(10, 12));
      final second = int.parse(dateTimePart.substring(12, 14));

      return DateTime(year, month, day, hour, minute, second);
    } catch (e) {
      return DateTime.now();
    }
  }
}

/// EPG 数据响应模型
class EpgData {
  final String tvgId;
  final String source;
  final String epgUrl;
  final List<EpgProgram> programs;

  EpgData({
    required this.tvgId,
    required this.source,
    required this.epgUrl,
    required this.programs,
  });

  factory EpgData.fromJson(Map<String, dynamic> json) {
    final tvgId = json['tvgId'] as String? ?? '';
    final programsList = json['programs'] as List<dynamic>? ?? [];

    return EpgData(
      tvgId: tvgId,
      source: json['source'] as String? ?? '',
      epgUrl: json['epgUrl'] as String? ?? '',
      programs: programsList
          .map((item) =>
              EpgProgram.fromApiJson(item as Map<String, dynamic>, tvgId))
          .toList(),
    );
  }
}
