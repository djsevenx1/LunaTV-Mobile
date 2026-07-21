/// v2.5.3: TVBox 协议 (`vod_id` / `vod_name` / `vod_pic` / ...) 短剧原始 model.
///
/// 之前 [ShortDrama] 走的是后端 `/api/shortdrama/*` 二次加工后的字段名
/// (`id` / `name` / `cover` / ...). 直连 TVBox 源拿到的 JSON 字段是
/// `vod_id` / `vod_name` / `vod_pic` / ..., 字段名 / 类型不通用, 单独 model
/// 解耦, 不污染老的 [ShortDrama] 逻辑.
///
/// 不包含 `episodes` / `episodes_titles` (即不含 m3u8 集数列表),
/// 因为按用户要求:
/// - 写死源 = 只提供 数据 + 图片 + 分类
/// - 播放 = 仍走 ShortDramaService.parseEpisode() 走后端解析
class RawShortDrama {
  final int vodId;
  final String vodName;
  final String vodPic;
  final String vodPicSlide;
  final String vodTime;
  final double vodScore;
  final int vodRemarksEpisodeCount;
  final String vodContent;
  final String vodBlurb;
  final String vodActor;
  final int typeId;
  final String typeName;

  const RawShortDrama({
    required this.vodId,
    required this.vodName,
    required this.vodPic,
    required this.vodPicSlide,
    required this.vodTime,
    required this.vodScore,
    required this.vodRemarksEpisodeCount,
    required this.vodContent,
    required this.vodBlurb,
    required this.vodActor,
    required this.typeId,
    required this.typeName,
  });

  /// 从 TVBox JSON (`?ac=detail&t=...`) 的一条 `list[]` 项解析.
  factory RawShortDrama.fromVodJson(Map<String, dynamic> json) {
    // 跟 src/lib/shortdrama.server.ts L62-66 字段映射 1:1, 复用后端解析逻辑.
    final remarks = json['vod_remarks']?.toString() ?? '';
    final epCount = int.tryParse(remarks.replaceAll(RegExp(r'[^\d]'), '')) ?? 1;
    final score =
        double.tryParse(json['vod_score']?.toString() ?? '') ?? 0.0;
    return RawShortDrama(
      vodId: json['vod_id'] is int
          ? json['vod_id']
          : int.tryParse(json['vod_id']?.toString() ?? '0') ?? 0,
      vodName: json['vod_name']?.toString() ?? '',
      vodPic: json['vod_pic']?.toString() ?? '',
      vodPicSlide: json['vod_pic_slide']?.toString() ?? '',
      vodTime: json['vod_time']?.toString() ?? '',
      vodScore: score,
      vodRemarksEpisodeCount: epCount,
      vodContent: json['vod_content']?.toString() ?? '',
      vodBlurb: json['vod_blurb']?.toString() ?? '',
      vodActor: json['vod_actor']?.toString() ?? '',
      typeId: json['type_id'] is int
          ? json['type_id']
          : int.tryParse(json['type_id']?.toString() ?? '0') ?? 0,
      typeName: json['type_name']?.toString() ?? '',
    );
  }
}

/// v2.5.3: TVBox 协议 (`?ac=list` 返的 `class[]`) 短剧原始分类.
class RawShortDramaCategory {
  final int typeId;
  final String typeName;

  const RawShortDramaCategory({
    required this.typeId,
    required this.typeName,
  });

  factory RawShortDramaCategory.fromVodJson(Map<String, dynamic> json) {
    return RawShortDramaCategory(
      typeId: json['type_id'] is int
          ? json['type_id']
          : int.tryParse(json['type_id']?.toString() ?? '0') ?? 0,
      typeName: json['type_name']?.toString() ?? '',
    );
  }
}
