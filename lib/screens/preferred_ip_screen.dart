import 'package:flutter/material.dart';
import 'package:luna_tv/services/preferred_ip.dart';
import 'package:luna_tv/services/user_data_service.dart';

/// 优选IP设置页面
/// 仿 cmliu/edgetunnel:
///   - 配置IP源URL
///   - 检测用户运营商 (移动/电信/联通)
///   - 一键测速优选, 显示前 N 快的IP
///   - 设置自动测速开关
class PreferredIpScreen extends StatefulWidget {
  const PreferredIpScreen({super.key});

  @override
  State<PreferredIpScreen> createState() => _PreferredIpScreenState();
}

class _PreferredIpScreenState extends State<PreferredIpScreen> {
  final _urlController = TextEditingController();
  bool _autoTest = true;
  bool _usePreferred = false;
  bool _loading = true;
  bool _testing = false;
  int _progress = 0;
  String _userIsp = '检测中...';
  String? _bestIp;
  List<MapEntry<String, int>> _results = [];
  DateTime? _lastTestTime;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final url = await PreferredIp.getSourceUrl();
    final auto = await PreferredIp.getAutoTest();
    final usePreferred = await UserDataService.getUsePreferredIp();
    final best = await PreferredIp.getBestIp();
    final isp = await PreferredIp.getBestIsp();
    final lastTime = await PreferredIp.getLastTestTime();
    final results = await PreferredIp.getLastResults();
    if (mounted) {
      setState(() {
        _urlController.text = url;
        _autoTest = auto;
        _usePreferred = usePreferred;
        _bestIp = best;
        _userIsp = isp;
        _lastTestTime = lastTime;
        _results = results;
        _loading = false;
      });
    }
  }

  Future<void> _saveUrl() async {
    await PreferredIp.setSourceUrl(_urlController.text.trim());
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已保存 IP 源 URL')),
    );
  }

  Future<void> _toggleAutoTest(bool v) async {
    await PreferredIp.setAutoTest(v);
    if (mounted) setState(() => _autoTest = v);
  }

  Future<void> _runTest() async {
    if (_testing) return;
    setState(() {
      _testing = true;
      _progress = 0;
    });
    try {
      final results = await PreferredIp.runPreferredIpTest(
        maxIps: 30,
        progressCallback: (cur, total) {
          if (mounted) setState(() => _progress = cur);
        },
      );
      if (!mounted) return;
      final isp = PreferredIp.userIsp;
      final best = results.isNotEmpty ? results.first.key : null;
      final lastTime = await PreferredIp.getLastTestTime();
      setState(() {
        _results = results;
        _userIsp = isp;
        _bestIp = best;
        _lastTestTime = lastTime;
        _testing = false;
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(results.isEmpty
                ? '测速失败, 请检查网络或更换 IP 源'
                : '测速完成, 运营商: $isp, 最优 IP: $best'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _testing = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('测速出错: $e')),
        );
      }
    }
  }

  Future<void> _clear() async {
    await PreferredIp.clear();
    if (!mounted) return;
    setState(() {
      _results = [];
      _bestIp = null;
      _userIsp = '未知';
      _lastTestTime = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已清除优选IP缓存')),
    );
  }

  String _formatLastTime(DateTime? t) {
    if (t == null) return '从未测速';
    final diff = DateTime.now().difference(t);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    return '${t.year}-${t.month.toString().padLeft(2, '0')}-${t.day.toString().padLeft(2, '0')} '
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Scaffold(
      backgroundColor:
          isDark ? const Color(0xFF0F1117) : const Color(0xFFF5F7F5),
      appBar: AppBar(
        title: const Text('优选IP'),
        backgroundColor: isDark ? const Color(0xFF1F2937) : Colors.white,
        foregroundColor: isDark ? Colors.white : Colors.black,
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                // 状态卡片
                _buildStatusCard(isDark),
                const SizedBox(height: 16),
                // IP源URL
                _buildSectionTitle('IP 源 URL', isDark),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _urlController,
                        style: TextStyle(
                          fontSize: 12,
                          color: isDark ? Colors.white : Colors.black,
                        ),
                        decoration: InputDecoration(
                          hintText: '优选IP 列表URL (每行一个IP)',
                          hintStyle: TextStyle(
                            fontSize: 12,
                            color: isDark ? Colors.white38 : Colors.black38,
                          ),
                          filled: true,
                          fillColor: isDark
                              ? const Color(0xFF1F2937)
                              : Colors.white,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide.none,
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: _saveUrl,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF22C55E),
                        foregroundColor: Colors.white,
                      ),
                      child: const Text('保存'),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Text(
                  '提示: IP 源格式为每行一个IP, 可用 cmliu/CF-IPQuality 等公共源',
                  style: TextStyle(
                    fontSize: 11,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
                const SizedBox(height: 16),
                // 自动测速开关
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1F2937)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.bolt, color: Color(0xFF22C55E)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('启动时自动测速',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                            Text(
                              'App启动时自动跑一次优选',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? Colors.white60
                                    : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _autoTest,
                        onChanged: _toggleAutoTest,
                        activeColor: const Color(0xFF22C55E),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 8),
                // 应用到播放请求开关
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: isDark
                        ? const Color(0xFF1F2937)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: _usePreferred
                          ? const Color(0xFF22C55E).withOpacity(0.5)
                          : Colors.transparent,
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.wifi, color: Color(0xFF22C55E)),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('应用到播放请求',
                                style: TextStyle(
                                    fontSize: 14, fontWeight: FontWeight.w600)),
                            Text(
                              _bestIp == null
                                  ? '请先测速获取最优IP, 默认关闭避免 SSL 错误'
                                  : '当前最优: $_bestIp',
                              style: TextStyle(
                                fontSize: 11,
                                color: isDark
                                    ? Colors.white60
                                    : Colors.black54,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Switch(
                        value: _usePreferred,
                        onChanged: (v) async {
                          if (v && _bestIp == null) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              const SnackBar(content: Text('请先测速获取最优IP')),
                            );
                            return;
                          }
                          await UserDataService.saveUsePreferredIp(v);
                          if (mounted) setState(() => _usePreferred = v);
                        },
                        activeColor: const Color(0xFF22C55E),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                // 测速按钮
                if (_testing)
                  Column(
                    children: [
                      const Text('测速中...', style: TextStyle(fontSize: 13)),
                      const SizedBox(height: 8),
                      LinearProgressIndicator(
                        value: _progress / 100,
                        backgroundColor: isDark
                            ? Colors.white12
                            : Colors.black12,
                        color: const Color(0xFF22C55E),
                      ),
                      const SizedBox(height: 4),
                      Text('$_progress%',
                          style: const TextStyle(fontSize: 12)),
                    ],
                  )
                else
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          onPressed: _runTest,
                          icon: const Icon(Icons.flash_on, size: 18),
                          label: const Text('开始测速优选'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF22C55E),
                            foregroundColor: Colors.white,
                            padding:
                                const EdgeInsets.symmetric(vertical: 12),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton.icon(
                        onPressed: _clear,
                        icon: const Icon(Icons.delete_outline, size: 18),
                        label: const Text('清除'),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.red,
                          side: const BorderSide(color: Colors.red),
                          padding:
                              const EdgeInsets.symmetric(vertical: 12),
                        ),
                      ),
                    ],
                  ),
                const SizedBox(height: 16),
                // 测速结果
                if (_results.isNotEmpty) ...[
                  _buildSectionTitle('测速结果 (按延迟升序)', isDark),
                  const SizedBox(height: 8),
                  ..._results.take(20).map((e) => _buildResultTile(e, isDark)),
                ],
              ],
            ),
    );
  }

  Widget _buildStatusCard(bool isDark) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF22C55E), Color(0xFF10B981)],
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.wifi_tethering, color: Colors.white, size: 24),
              const SizedBox(width: 8),
              const Text('优选IP 状态',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('当前运营商',
                        style: TextStyle(
                            color: Colors.white70, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      _userIsp,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('最优 IP',
                        style: TextStyle(
                            color: Colors.white70, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      _bestIp ?? '未测速',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '上次测速: ${_formatLastTime(_lastTestTime)}',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, bool isDark) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w700,
        color: isDark ? Colors.white : Colors.black87,
      ),
    );
  }

  Widget _buildResultTile(MapEntry<String, int> entry, bool isDark) {
    final ms = entry.value;
    final isBest = _bestIp == entry.key;
    final color = ms < 200
        ? const Color(0xFF22C55E)
        : (ms < 500
            ? const Color(0xFFF59E0B)
            : (ms < 1500
                ? const Color(0xFFF97316)
                : const Color(0xFFEF4444)));
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF1F2937) : Colors.white,
        borderRadius: BorderRadius.circular(8),
        border: isBest
            ? Border.all(color: const Color(0xFF22C55E), width: 1.5)
            : null,
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withOpacity(0.15),
              borderRadius: BorderRadius.circular(6),
            ),
            alignment: Alignment.center,
            child: Text(
              '#${_results.indexOf(entry) + 1}',
              style: TextStyle(
                color: color,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.key,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: isDark ? Colors.white : Colors.black87,
                  ),
                ),
                Text(
                  'Cloudflare 优选',
                  style: TextStyle(
                    fontSize: 10,
                    color: isDark ? Colors.white38 : Colors.black38,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: color.withOpacity(0.12),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${ms}ms',
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          if (isBest) ...[
            const SizedBox(width: 8),
            const Icon(Icons.check_circle, color: Color(0xFF22C55E), size: 18),
          ],
        ],
      ),
    );
  }

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }
}
