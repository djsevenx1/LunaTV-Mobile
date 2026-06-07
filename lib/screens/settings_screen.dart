import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/services/content_filter_service.dart';
import 'filter_settings_screen.dart';
import 'package:luna_tv/services/content_filter_service.dart';
import 'filter_settings_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('设置'),
        elevation: 0,
      ),
      body: ListView(
        children: const [
          _Section(label: '账户'),
          _ServerUrlTile(),
          _DoubanSourceTile(),
          _DoubanImageTile(),
          _LogoutTile(),
          _DividerTile(),
          _Section(label: '播放偏好'),
          _M3uProxyTile(),
          _SpeedTestTile(),
          _DividerTile(),
          _Section(label: '外观'),
          _ThemeTile(),
          _DividerTile(),
          _M3uImportTile(),
          _Section(label: '内容过滤'),
          const _FilterEntryTile(),
          _DividerTile(),
          _Section(label: '关于'),
          _AboutTile(),
        ],
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String label;
  const _Section({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 18, 16, 8),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: color,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

class _DividerTile extends StatelessWidget {
  const _DividerTile();

  @override
  Widget build(BuildContext context) => const Divider(height: 1, indent: 16, endIndent: 16);
}

class _ServerUrlTile extends StatefulWidget {
  const _ServerUrlTile();

  @override
  State<_ServerUrlTile> createState() => _ServerUrlTileState();
}

class _ServerUrlTileState extends State<_ServerUrlTile> {
  final _controller = TextEditingController();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await UserDataService.getServerUrl();
    if (mounted && v != null) _controller.text = v;
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('服务器地址'),
      subtitle: TextField(
        controller: _controller,
        decoration: const InputDecoration(
          hintText: 'https://example.com',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onSubmitted: (v) async {
          await UserDataService.saveServerUrl(v);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
        },
      ),
      trailing: IconButton(
        icon: const Icon(Icons.save_outlined),
        onPressed: () async {
          await UserDataService.saveServerUrl(_controller.text);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
        },
      ),
    );
  }
}

class _DoubanSourceTile extends StatefulWidget {
  const _DoubanSourceTile();

  @override
  State<_DoubanSourceTile> createState() => _DoubanSourceTileState();
}

class _DoubanSourceTileState extends State<_DoubanSourceTile> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final v = await UserDataService.getDoubanDataSource();
    if (mounted) setState(() => _value = v ?? '111029');
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('豆瓣数据源'),
      trailing: DropdownButton<String>(
        value: _value,
        hint: const Text('选择'),
        items: const [
          DropdownMenuItem(value: '111029', child: Text('默认源')),
          DropdownMenuItem(value: 'other', child: Text('备选')),
        ],
        onChanged: (v) async {
          if (v == null) return;
          await UserDataService.setDoubanDataSource(v);
          setState(() => _value = v);
        },
      ),
    );
  }
}

class _DoubanImageTile extends StatefulWidget {
  const _DoubanImageTile();

  @override
  State<_DoubanImageTile> createState() => _DoubanImageTileState();
}

class _DoubanImageTileState extends State<_DoubanImageTile> {
  String? _value;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    final v = await UserDataService.getDoubanImageSource();
    if (mounted) setState(() => _value = v ?? 'original');
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('豆瓣图片源'),
      trailing: DropdownButton<String>(
        value: _value,
        items: const [
          DropdownMenuItem(value: 'original', child: Text('原图')),
          DropdownMenuItem(value: 'webp', child: Text('WebP')),
        ],
        onChanged: (v) async {
          if (v == null) return;
          await UserDataService.setDoubanImageSource(v);
          setState(() => _value = v);
        },
      ),
    );
  }
}

class _M3uProxyTile extends StatefulWidget {
  const _M3uProxyTile();

  @override
  State<_M3uProxyTile> createState() => _M3uProxyTileState();
}

class _M3uProxyTileState extends State<_M3uProxyTile> {
  final _c = TextEditingController();

  @override
  void initState() {
    super.initState();
    UserDataService.getM3u8ProxyUrl().then((v) {
      if (mounted && v != null) _c.text = v;
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('M3U8 代理地址'),
      subtitle: TextField(
        controller: _c,
        decoration: const InputDecoration(
          hintText: '留空则直连',
          isDense: true,
          contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onSubmitted: (v) async {
          await UserDataService.setM3u8ProxyUrl(v);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
        },
      ),
      trailing: IconButton(
        icon: const Icon(Icons.save_outlined),
        onPressed: () async {
          await UserDataService.setM3u8ProxyUrl(_c.text);
          if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已保存')));
        },
      ),
    );
  }
}

class _SpeedTestTile extends StatefulWidget {
  const _SpeedTestTile();

  @override
  State<_SpeedTestTile> createState() => _SpeedTestTileState();
}

class _SpeedTestTileState extends State<_SpeedTestTile> {
  bool _checked = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final v = await UserDataService.getPreferSpeedTest();
    if (mounted) setState(() => _checked = v);
  }

  @override
  Widget build(BuildContext context) {
    return SwitchListTile(
      title: const Text('优先测速选择线路'),
      value: _checked,
      onChanged: (v) async {
        await UserDataService.setPreferSpeedTest(v);
        setState(() => _checked = v);
      },
    );
  }
}

class _ThemeTile extends StatelessWidget {
  const _ThemeTile();

  @override
  Widget build(BuildContext context) {
    final mode = context.watch<ThemeService>().themeMode2;
    String label;
    switch (mode) {
      case ThemeMode.light:
        label = '浅色';
      case ThemeMode.dark:
        label = '深色';
      case ThemeMode.system:
      default:
        label = '跟随系统';
    }
    return ListTile(
      title: const Text('主题'),
      trailing: DropdownButton<ThemeMode>(
        value: mode,
        items: const [
          DropdownMenuItem(value: ThemeMode.system, child: Text('跟随系统')),
          DropdownMenuItem(value: ThemeMode.light, child: Text('浅色')),
          DropdownMenuItem(value: ThemeMode.dark, child: Text('深色')),
        ],
        onChanged: (v) {
          if (v == null) return;
          context.read<ThemeService>().setThemeMode(v);
        },
      ),
    );
  }
}

class _LogoutTile extends StatelessWidget {
  const _LogoutTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text(
        '退出登录',
        style: TextStyle(color: Colors.redAccent),
      ),
      onTap: () async {
        final confirm = await showDialog<bool>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('确认退出？'),
            content: const Text('清除 cookies 和登录信息'),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
              TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('退出')),
            ],
          ),
        );
        if (confirm == true) {
          await UserDataService.clearPasswordAndCookies();
          if (mounted) Navigator.of(context).popUntil((r) => r.isFirst);
        }
      },
    );
  }
}

class _M3uImportTile extends StatelessWidget {
  const _M3uImportTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.upload_file_rounded),
      title: const Text('导入 M3U / 订阅'),
      subtitle: const Text('从 URL 导入播放列表，自动切换本地模式'),
      onTap: () {
        Navigator.of(context).pushNamed('/m3u-import');
      },
    );
  }
}

class _FilterEntryTile extends StatelessWidget {
  const _FilterEntryTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.block_outlined),
      title: const Text('关键词过滤'),
      subtitle: const Text('自定义黑名单关键词'),
      onTap: () {
        Navigator.of(context).pushNamed('/filter-settings');
      },
    );
  }
}

class _AboutTile extends StatelessWidget {
  const _AboutTile();

  @override
  Widget build(BuildContext context) {
    return ListTile(
      title: const Text('关于 LunaTV-Mobile'),
      subtitle: const Text('以 MoonTV v100 / Helios 为后端的 Flutter 客户端'),
      onTap: () {
        showAboutDialog(
          context: context,
          applicationName: 'LunaTV-Mobile',
          applicationVersion: '1.0.0',
        );
      },
    );
  }
}

class _FilterTile extends StatelessWidget {
  const _FilterTile();
  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.filter_list_outlined),
      title: const Text('关键词过滤'),
      subtitle: const Text('管理自定义过滤关键词'),
      onTap: () {
        Navigator.of(context).pushNamed('/filter-settings');
      },
    );
  }
}
