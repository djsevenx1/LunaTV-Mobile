import 'package:luna_tv/video_info.dart';

/// 豆瓣推荐项目数据模型
class DoubanRecommendItem {
  final String id;
  final String title;
  final String poster;
  final String? rate;

  const DoubanRecommendItem({
    required this.id,
    required this.title,
    required this.poster,
    this.rate,
  });

  /// 从JSON创建DoubanRecommendItem实例
  factory DoubanRecommendItem.fromJson(Map<String, dynamic> json) {
    return DoubanRecommendItem(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: json['poster']?.toString() ?? '',
      rate: json['rate']?.toString(),
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'poster': poster,
      'rate': rate,
    };
  }

  /// 转换为VideoInfo格式，用于VideoCard显示
  VideoInfo toVideoInfo() {
    return VideoInfo(
      id: id,
      source: 'douban',
      title: title,
      sourceName: '豆瓣',
      year: '', // 推荐项目没有年份信息
      cover: poster,
      index: 1,
      totalEpisodes: 1,
      playTime: 0,
      totalTime: 0,
      saveTime: DateTime.now().millisecondsSinceEpoch,
      searchTitle: title,
      doubanId: id,
      rate: rate,
    );
  }
}

/// 豆瓣电影详情数据模型
class DoubanMovieDetails {
  final String id;
  final String title;
  final String poster;
  final String? rate;
  final String year;
  final String? summary;
  final List<String> genres;
  final List<String> directors;
  final List<String> screenwriters;
  final List<String> actors;
  final String? duration;
  final List<String> countries;
  final List<String> languages;
  final String? releaseDate;
  final String? originalTitle;
  final String? imdbId;
  final int? totalEpisodes;
  final List<DoubanRecommendItem> recommends;

  const DoubanMovieDetails({
    required this.id,
    required this.title,
    required this.poster,
    this.rate,
    required this.year,
    this.summary,
    this.genres = const [],
    this.directors = const [],
    this.screenwriters = const [],
    this.actors = const [],
    this.duration,
    this.countries = const [],
    this.languages = const [],
    this.releaseDate,
    this.originalTitle,
    this.imdbId,
    this.totalEpisodes,
    this.recommends = const [],
  });

  /// 从JSON创建DoubanMovieDetails实例
  factory DoubanMovieDetails.fromJson(Map<String, dynamic> json) {
    String? nonEmptyString(dynamic value) {
      final stringValue = value?.toString().trim();
      if (stringValue == null || stringValue.isEmpty || stringValue == 'null') {
        return null;
      }
      return stringValue;
    }

    List<String> stringList(dynamic value) {
      if (value is List) {
        return value
            .map(nonEmptyString)
            .whereType<String>()
            .toList();
      }
      final singleValue = nonEmptyString(value);
      return singleValue == null ? <String>[] : <String>[singleValue];
    }

    List<String> nameList(dynamic value) {
      if (value is! List) {
        return <String>[];
      }

      return value
          .map((item) {
            if (item is Map<String, dynamic>) {
              return nonEmptyString(item['name']);
            }
            return nonEmptyString(item);
          })
          .whereType<String>()
          .toList();
    }

    int? parseInt(dynamic value) {
      if (value is int) {
        return value;
      }
      return int.tryParse(value?.toString() ?? '');
    }

    // 处理poster字段
    String poster = '';
    if (json['poster'] != null) {
      poster = json['poster']?.toString() ?? '';
    } else if (json['cover_url'] != null) {
      poster = json['cover_url']?.toString() ?? '';
    } else if (json['images'] != null) {
      final images = json['images'] as Map<String, dynamic>?;
      poster = images?['large']?.toString() ?? 
               images?['medium']?.toString() ?? 
               images?['small']?.toString() ?? '';
    } else if (json['pic'] != null) {
      final pic = json['pic'] as Map<String, dynamic>?;
      poster = pic?['large']?.toString() ??
               pic?['normal']?.toString() ??
               pic?['medium']?.toString() ??
               pic?['small']?.toString() ?? '';
    }
    
    // 处理rating字段
    String? rate = nonEmptyString(json['rate']);
    if (rate == null && json['rating'] != null) {
      final rating = json['rating'] as Map<String, dynamic>?;
      final value = rating?['average'] ?? rating?['value'];
      if (value != null) {
        if (value is num) {
          rate = value.toStringAsFixed(1);
        } else {
          rate = value.toString();
        }
      }
    }
    if (rate == '0' || rate == '0.0') {
      rate = null;
    }
    
    // 处理年份
    String year = json['year']?.toString() ?? '';
    if (year.isEmpty && json['pubdate'] != null) {
      final pubdate = stringList(json['pubdate']).join(' ');
      final yearMatch = RegExp(r'(\d{4})').firstMatch(pubdate);
      year = yearMatch?.group(1) ?? '';
    }
    
    // 处理导演列表
    final directors = json['directors'] is List &&
            (json['directors'] as List).any((item) => item is Map)
        ? nameList(json['directors'])
        : stringList(json['directors']);
    
    // 处理编剧列表
    final screenwriters = json['screenwriters'] is List &&
            (json['screenwriters'] as List).any((item) => item is Map)
        ? nameList(json['screenwriters'])
        : stringList(json['screenwriters']);
    
    // 处理演员列表
    final actorsSource = json['actors'] ?? json['casts'];
    final actors = actorsSource is List && actorsSource.any((item) => item is Map)
        ? nameList(actorsSource)
        : stringList(actorsSource);
    
    // 处理类型列表
    final genres = stringList(json['genres']);
    
    // 处理国家列表
    final countries = stringList(json['countries']);
    
    // 处理语言列表
    final languages = stringList(json['languages']);
    
    // 处理推荐列表
    List<DoubanRecommendItem> recommends = [];
    if (json['recommends'] != null) {
      final recommendsData = json['recommends'] as List<dynamic>? ?? [];
      recommends = recommendsData.map((r) => DoubanRecommendItem.fromJson(r as Map<String, dynamic>)).toList();
    }
    
    // 处理总集数
    final totalEpisodes = parseInt(
      json['episodes_count'] ?? json['totalEpisodes'] ?? json['total_episodes'],
    );
    final pubdates = stringList(json['pubdate']);
    final durations = stringList(json['durations']);
    
    return DoubanMovieDetails(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: poster,
      rate: rate,
      year: year,
      summary: nonEmptyString(json['summary'] ?? json['intro']),
      genres: genres,
      directors: directors,
      screenwriters: screenwriters,
      actors: actors,
      duration: nonEmptyString(json['duration']) ??
          (durations.isNotEmpty ? durations.first : null),
      countries: countries,
      languages: languages,
      releaseDate: nonEmptyString(json['releaseDate']) ??
          (pubdates.isNotEmpty ? pubdates.first : null),
      originalTitle: nonEmptyString(json['originalTitle'] ?? json['original_title']),
      imdbId: nonEmptyString(json['imdbId'] ?? json['imdb']),
      totalEpisodes: totalEpisodes,
      recommends: recommends,
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'poster': poster,
      'rate': rate,
      'year': year,
      'summary': summary,
      'genres': genres,
      'directors': directors,
      'screenwriters': screenwriters,
      'actors': actors,
      'duration': duration,
      'countries': countries,
      'languages': languages,
      'releaseDate': releaseDate,
      'originalTitle': originalTitle,
      'imdbId': imdbId,
      'totalEpisodes': totalEpisodes,
      'recommends': recommends.map((r) => r.toJson()).toList(),
    };
  }
}

/// 豆瓣电影数据模型
class DoubanMovie {
  final String id;
  final String title;
  final String poster;
  final String? rate;
  final String year;

  const DoubanMovie({
    required this.id,
    required this.title,
    required this.poster,
    this.rate,
    required this.year,
  });

  /// 从JSON创建DoubanMovie实例
  factory DoubanMovie.fromJson(Map<String, dynamic> json) {
    // 处理poster字段，优先使用normal，其次large
    String poster = '';
    if (json['pic'] != null) {
      final pic = json['pic'] as Map<String, dynamic>?;
      poster = pic?['normal']?.toString() ?? 
               pic?['large']?.toString() ?? '';
    }
    
    // 处理rating字段
    String? rate;
    if (json['rating'] != null) {
      final rating = json['rating'] as Map<String, dynamic>?;
      final value = rating?['value'];
      if (value != null) {
        rate = (value as num).toStringAsFixed(1);
      }
    }
    
    // 处理年份，从card_subtitle中提取
    String year = '';
    if (json['card_subtitle'] != null) {
      final cardSubtitle = json['card_subtitle']?.toString() ?? '';
      final yearMatch = RegExp(r'(\d{4})').firstMatch(cardSubtitle);
      year = yearMatch?.group(1) ?? '';
    }
    
    return DoubanMovie(
      id: json['id']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      poster: poster,
      rate: rate,
      year: year,
    );
  }

  /// 转换为JSON
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'title': title,
      'poster': poster,
      'rate': rate,
      'year': year,
    };
  }

  /// 转换为VideoInfo格式，用于VideoCard显示
  VideoInfo toVideoInfo() {
    return VideoInfo(
      id: id,
      source: 'douban',
      title: title,
      sourceName: '豆瓣',
      year: year,
      cover: poster,
      index: 1,
      totalEpisodes: 1,
      playTime: 0,
      totalTime: 0,
      saveTime: DateTime.now().millisecondsSinceEpoch,
      searchTitle: title,
      doubanId: id,
      rate: rate,
    );
  }

}

/// 豆瓣API响应模型
class DoubanResponse {
  final List<DoubanMovie> items;

  const DoubanResponse({
    required this.items,
  });

  /// 从JSON创建DoubanResponse实例
  factory DoubanResponse.fromJson(Map<String, dynamic> json) {
    final itemsData = json['items'] as List<dynamic>? ?? [];
    
    return DoubanResponse(
      items: itemsData.map((item) {
        return DoubanMovie.fromJson(item as Map<String, dynamic>);
      }).toList(),
    );
  }
}
