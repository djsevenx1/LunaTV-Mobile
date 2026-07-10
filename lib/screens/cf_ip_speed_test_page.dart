import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import 'package:luna_tv/services/cf_optimizer.dart';
import 'package:luna_tv/utils/font_utils.dart';

/// v2.0.82: CF IP 优选测速页面
///
/// 跟 v2.0.30 砍掉的"测延迟"功能不同:
///   - 老功能: 只测 TCP 443 握手延迟, 自动存 Top 3
///   - 新功能: 测延迟 + 1MB 下载速度, 列表按速度降序, 用户点选存优选
///
/// 参考: https://www.6ird.com/tools/cfip/  (CF IP 优选工具)
class CfIpSpeedTestPage extends StatefulWidget {
  /// 已配的 worker 自定义域名 (从 CfAccelerationPage 传过来)
  final String workerDomain;

  const CfIpSpeedTestPage({super.key, required this.workerDomain});

  @override
  State<CfIpSpeedTestPage> createState() => _CfIpSpeedTestPageState();
}

class _CfIpSpeedTestPageState extends State<CfIpSpeedTestPage> {
  bool _isProbing = false;
  int _done = 0;
  int _total = 0;
  String? _err;
  // 测速结果, 按速度降序
  List<({String ip, int latencyMs, double mbPerSec, int httpCode})> _results =
      const [];

  @override
  void initState() {
    super.initState();
    // 进入页面自动跑一次
    if (widget.workerDomain.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _runProbe();
      });
    }
  }

  Future<void> _runProbe() async {
    if (_isProbing) return;
    if (widget.workerDomain.isEmpty) {
      setState(() {
        _err = '请先在「CF 加速」页面配置 Worker 加速源域名';
      });
      return;
    }
    setState(() {
      _isProbing = true;
      _done = 0;
      _total = 0;
      _err = null;
      _results = const [];
    });
    try {
      final results = await CfOptimizer.runSpeedTest(
        targetDomain: widget.workerDomain,
        testMB: 1,
        maxIps: 30,
        concurrency: 6,
        timeout: const Duration(seconds: 10),
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _done = done;
            _total = total;
          });
        },
      );
      if (!mounted) return;
      setState(() {
        _results = results;
        _isProbing = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _err = e.toString();
        _isProbing = false;
      });
    }
  }

  Future<void> _saveAndPop(String ip) async {
    await CfOptimizer.saveManualBestIp(ip);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('已保存优选 IP: $ip'),
        backgroundColor: const Color(0xFF10B981),
        duration: const Duration(seconds: 2),
      ),
    );
    // 跳回上一页
    Navigator.of(context).pop(ip);
  }

  String _httpCodeHuman(int code) {
    if (code == 0) return '连接失败';
    if (code == -1) return '超时';
    if (code == -2) return 'SSL 失败';
    if (code == -3) return '其他错误';
    return 'HTTP $code';
  }

  Color _speedColor(double mbps, bool isDark) {
    if (mbps <= 0) return isDark ? const Color(0xFF6B7280) : const Color(0xFF9CA3AF);
    if (mbps >= 5) return const Color(0xFF10B981); // 绿
    if (mbps >= 2) return const Color(0xFFF59E0B); // 黄
    return const Color(0xFFEF4444); // 红
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF101010) : const Color(0xFFF5F5F5);
    final cardColor = isDark ? const Color(0xFF1c1c1c) : Colors.white;
    final primaryTextColor =
        isDark ? const Color(0xFFffffff) : const Color(0xFF1f2937);
    final subtitleColor =
        isDark ? const Color(0xFF9ca3af) : const Color(0xFF6b7280);

    return Scaffold(
      backgroundColor: bgColor,
      appBar: AppBar(
        backgroundColor: bgColor,
        elevation: 0,
        title: Text(
          'CF IP 优选测速',
          style: FontUtils.poppins(context,
              fontSize: 18,
              color: primaryTextColor,
              fontWeight: FontWeight.w600),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: primaryTextColor),
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: Icon(LucideIcons.refreshCw,
                color: _isProbing ? subtitleColor : primaryTextColor,
                size: 20),
            onPressed: _isProbing ? null : _runProbe,
            tooltip: '重新测速',
          ),
        ],
      ),
      body: Column(
        children: [
          // 顶部说明
          Container(
            margin: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(LucideIcons.info,
                        size: 16, color: subtitleColor),
                    const SizedBox(width: 6),
                    Text(
                      '扫描 ${widget.workerDomain}',
                      style: FontUtils.sourceCodePro(context,
                          fontSize: 13,
                          color: primaryTextColor,
                          fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  _isProbing
                      ? '测速中: $_done / $_total'
                      : _results.isNotEmpty
                          ? '完成 ${_results.length} 个 IP 测速, 按下载速度降序. 点「使用」存为优选 IP.'
                          : '开始测速, 大约 30 秒...',
                  style: FontUtils.sourceCodePro(context,
                      fontSize: 12, color: subtitleColor),
                ),
                if (_isProbing) ...[
                  const SizedBox(height: 10),
                  LinearProgressIndicator(
                    minHeight: 4,
                    backgroundColor: subtitleColor.withOpacity(0.2),
                    value: _total > 0 ? _done / _total : null,
                  ),
                ],
                if (_err != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    '错误: $_err',
                    style: FontUtils.sourceCodePro(context,
                        fontSize: 12, color: const Color(0xFFEF4444)),
                  ),
                ],
              ],
            ),
          ),
          // 列表
          Expanded(
            child: _results.isEmpty
                ? Center(
                    child: _isProbing
                        ? const SizedBox.shrink()
                        : Text(
                            _err != null ? '测速失败, 点击右上角重试' : '暂无数据',
                            style: FontUtils.poppins(context,
                                fontSize: 14, color: subtitleColor),
                          ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    itemCount: _results.length,
                    itemBuilder: (ctx, i) {
                      final r = _results[i];
                      final isFailed = r.mbPerSec <= 0;
                      return Container(
                        margin: const EdgeInsets.only(bottom: 8),
                        padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
                        decoration: BoxDecoration(
                          color: cardColor,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            // 排名
                            SizedBox(
                              width: 28,
                              child: Text(
                                isFailed
                                    ? '—'
                                    : '#${(i + 1).toString().padLeft(2, '0')}',
                                style: FontUtils.sourceCodePro(context,
                                    fontSize: 13,
                                    color: i < 3 && !isFailed
                                        ? const Color(0xFF10B981)
                                        : subtitleColor,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            // IP
                            Expanded(
                              flex: 3,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    r.ip,
                                    style: FontUtils.sourceCodePro(context,
                                        fontSize: 14,
                                        color: primaryTextColor,
                                        fontWeight: FontWeight.w600),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    isFailed
                                        ? _httpCodeHuman(r.httpCode)
                                        : '${r.latencyMs}ms',
                                    style: FontUtils.sourceCodePro(context,
                                        fontSize: 11, color: subtitleColor),
                                  ),
                                ],
                              ),
                            ),
                            // 速度
                            SizedBox(
                              width: 78,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.end,
                                children: [
                                  Text(
                                    isFailed
                                        ? '—'
                                        : '${r.mbPerSec.toStringAsFixed(2)} MB/s',
                                    style: FontUtils.sourceCodePro(context,
                                        fontSize: 13,
                                        color: _speedColor(r.mbPerSec, isDark),
                                        fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 6),
                            // 使用按钮
                            TextButton(
                              onPressed: isFailed ? null : () => _saveAndPop(r.ip),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 6),
                                minimumSize: Size.zero,
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: isFailed
                                    ? subtitleColor
                                    : const Color(0xFF3B82F6),
                              ),
                              child: Text(
                                '使用',
                                style: FontUtils.poppins(context,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
