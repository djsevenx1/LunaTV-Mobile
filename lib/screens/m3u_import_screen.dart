import 'package:luna_tv/services/user_data_service.dart';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:luna_tv/services/subscription_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';
import 'package:luna_tv/services/search_service.dart';

class M3uImportScreen extends StatefulWidget {
  const M3uImportScreen({super.key});

  @override
  State<M3uImportScreen> createState() => _M3uImportScreenState();
}

class _M3uImportScreenState extends State<M3uImportScreen> {
  final _controller = TextEditingController();
  bool _isLoading = false;
  String? _error;
  String? _success;

  @override
  void initState() {
    super.initState();
    _loadLastUrl();
  }

  Future<void> _loadLastUrl() async {
    final prefs = await SharedPreferences.getInstance();
    final last = prefs.getString('last_m3u_import_url');
    if (mounted && last != null && last.isNotEmpty) {
      _controller.text = last;
    }
  }

  Future<void> _importFromUrl() async {
    final url = _controller.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _isLoading = true;
      _error = null;
      _success = null;
    });
    try {
      final response = await http.get(Uri.parse(url)).timeout(
        const Duration(seconds: 30),
        onTimeout: () => throw TimeoutException('请求超时'),
      );
      if (response.statusCode != 200) {
        throw Exception('HTTP ${response.statusCode}');
      }
      final content = response.body;
      await _parseAndSave(content, url);
    } on TimeoutException catch (e) {
      if (mounted) setState(() => _error = '超时：${e.message}');
    } catch (e) {
      if (mounted) setState(() => _error = '导入失败：$e');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _parseAndSave(String content, String url) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_m3u_import_url', url);

    // 复用 SubscriptionService 解析
    final parsed = await SubscriptionService.parseSubscriptionContent(content);
    if (parsed == null) {
      setState(() => _error = '无法解析此链接，请确认是有效的订阅/M3U 地址');
      return;
    }

    int savedCount = 0;
    if (parsed.searchResources != null && parsed.searchResources!.isNotEmpty) {
      await LocalModeStorageService.saveSearchSources(parsed.searchResources!);
      savedCount += parsed.searchResources!.length;
    }
    if (parsed.liveSources != null && parsed.liveSources!.isNotEmpty) {
      await LocalModeStorageService.saveLiveSources(parsed.liveSources!);
      savedCount += parsed.liveSources!.length;
    }

    // 同时切换到本地模式
    await UserDataService.setLocalMode(true);

    setState(() {
      _success = '导入成功，共 $savedCount 个源。已自动切换到本地模式。';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('导入 M3U / 订阅'),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            '输入 M3U 播放列表或订阅地址，自动解析并切换到本地模式。',
            style: TextStyle(fontSize: 14, color: Colors.black54),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _controller,
            decoration: InputDecoration(
              labelText: '订阅 / M3U 地址',
              hintText: 'https://example.com/subscribe.m3u',
              border: const OutlineInputBorder(),
              suffixIcon: _isLoading
                  ? const Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : null,
            ),
            onSubmitted: (_) => _importFromUrl(),
            enabled: !_isLoading,
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: FilledButton.icon(
                  onPressed: _isLoading ? null : _importFromUrl,
                  icon: const Icon(Icons.download_rounded),
                  label: const Text('导入'),
                ),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _isLoading ? null : () async {
                  try {
                    final prefs = await SharedPreferences.getInstance();
                    final last = prefs.getString('last_m3u_import_url');
                    if (last != null && last.isNotEmpty) {
                      _controller.text = last;
                    }
                  } catch (_) {}
                },
                icon: const Icon(Icons.history_rounded),
                label: const Text('最近'),
              ),
            ],
          ),
          const SizedBox(height: 20),
          if (_error != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.red.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.red.shade200),
              ),
              child: Text(_error!, style: TextStyle(color: Colors.red.shade700)),
            ),
          if (_success != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green.shade200),
              ),
              child: Text(_success!, style: TextStyle(color: Colors.green.shade700)),
            ),
        ],
      ),
    );
  }
}
