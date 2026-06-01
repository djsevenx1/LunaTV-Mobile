import 'live_channel.dart';

/// M3U 内容
class M3uContent {
  final String tvgUrl;
  final List<LiveChannel> channels;

  M3uContent({
    required this.tvgUrl,
    required this.channels,
  });
}
