import 'dart:async';
import 'package:flutter/material.dart';
import 'package:dlna_dart/dlna.dart';

class DLNADeviceDialog extends StatefulWidget {
  final String currentUrl;
  final Function(DLNADevice)? onCastStarted;
  final DLNADevice? currentDevice;
  final Duration? resumePosition;
  final String? videoTitle;
  final int? currentEpisodeIndex;
  final int? totalEpisodes;
  final String? sourceName;

  const DLNADeviceDialog({
    super.key, 
    required this.currentUrl,
    this.onCastStarted,
    this.currentDevice,
    this.resumePosition,
    this.videoTitle,
    this.currentEpisodeIndex,
    this.totalEpisodes,
    this.sourceName,
  });

  @override
  State<DLNADeviceDialog> createState() => _DLNADeviceDialogState();
}

class _DLNADeviceDialogState extends State<DLNADeviceDialog> {
  DLNAManager? _dlnaManager;
  Map<String, DLNADevice> _devices = {};
  bool _isScanning = false;
  String _scanStatus = '准备扫描设备...';
  Timer? _scanTimer;
  StreamSubscription? _devicesSubscription;
  int _scanGeneration = 0;

  @override
  void initState() {
    super.initState();
    _startScanning();
  }

  @override
  void dispose() {
    _stopScanning();
    super.dispose();
  }

  Future<void> _startScanning() async {
    if (!mounted) return;

    final scanGeneration = ++_scanGeneration;

    try {
      setState(() {
        _isScanning = true;
        _scanStatus = '正在扫描DLNA设备...';
      });

      final dlnaManager = DLNAManager();
      _dlnaManager = dlnaManager;
      final manager = await dlnaManager.start();
      if (!mounted || scanGeneration != _scanGeneration) {
        dlnaManager.stop();
        return;
      }
      
      // 监听设备发现
      await _devicesSubscription?.cancel();
      _devicesSubscription = manager.devices.stream.listen((deviceList) {
        if (mounted) {
          setState(() {
            _devices = deviceList;
            _scanStatus = '发现 ${_devices.length} 个设备';
          });
        }
      });

      // 设置扫描超时
      _scanTimer = Timer(const Duration(seconds: 10), () {
        if (mounted) {
          setState(() {
            _isScanning = false;
            _scanStatus = '扫描完成，发现 ${_devices.length} 个设备';
          });
        }
      });

    } catch (e) {
      if (mounted) {
        setState(() {
          _isScanning = false;
          _scanStatus = '扫描失败: $e';
        });
      }
    }
  }

  void _stopScanning() {
    _scanGeneration++;
    _scanTimer?.cancel();
    _devicesSubscription?.cancel();
    _devicesSubscription = null;
    _dlnaManager?.stop();
  }

  void _refreshScanning() {
    _stopScanning();
    _devices.clear();
    _startScanning();
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    // 平板模式下使用更小的宽度比例
    final isTablet = screenWidth >= 600;
    final dialogWidth = isTablet 
        ? screenWidth * 0.5  // 平板：50%
        : screenWidth * 0.9; // 手机：90%
    
    return Dialog(
      backgroundColor: Colors.transparent,
        child: Container(
        width: dialogWidth,
        height: MediaQuery.of(context).size.height * 0.7,
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: Theme.of(context).dialogTheme.backgroundColor ?? Theme.of(context).colorScheme.surface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 标题栏
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '选择投屏设备',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).textTheme.titleLarge?.color,
                  ),
                ),
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
            const SizedBox(height: 16),
            
            // 扫描状态
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  if (_isScanning)
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  else
                    Icon(
                      Icons.wifi_find,
                      size: 16,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _scanStatus,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 14,
                      ),
                    ),
                  ),
                  if (!_isScanning)
                    TextButton(
                      onPressed: _refreshScanning,
                      child: const Text('重新扫描'),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            
            // 设备列表
            Expanded(
              child: _devices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.devices_other,
                            size: 64,
                            color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity( 0.5),
                          ),
                          const SizedBox(height: 16),
                          Text(
                            _isScanning ? '正在搜索设备...' : '未发现DLNA设备',
                            style: TextStyle(
                              fontSize: 16,
                              color: Theme.of(context).colorScheme.onSurfaceVariant,
                            ),
                          ),
                          if (!_isScanning) ...[
                            const SizedBox(height: 8),
                            Text(
                              '请确保设备与手机在同一网络下',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(context).colorScheme.onSurfaceVariant.withOpacity( 0.7),
                              ),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _devices.length,
                      itemBuilder: (context, index) {
                        final deviceEntry = _devices.entries.elementAt(index);
                        final device = deviceEntry.value;
                        final isCurrentDevice = widget.currentDevice != null && 
                            device.info.friendlyName == widget.currentDevice!.info.friendlyName;
                        
                        return Container(
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: isCurrentDevice 
                                ? Theme.of(context).colorScheme.primaryContainer
                                : Theme.of(context).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(8),
                            border: isCurrentDevice 
                                ? Border.all(
                                    color: Theme.of(context).colorScheme.primary,
                                    width: 2,
                                  )
                                : null,
                          ),
                          child: ListTile(
                            leading: Icon(
                              _getDeviceIcon(device.info.friendlyName),
                              color: isCurrentDevice 
                                  ? Theme.of(context).colorScheme.primary
                                  : Theme.of(context).colorScheme.primary,
                            ),
                            title: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    device.info.friendlyName,
                                    style: TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: Theme.of(context).textTheme.titleMedium?.color,
                                    ),
                                  ),
                                ),
                                if (isCurrentDevice)
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: Theme.of(context).colorScheme.primary,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      '当前设备',
                                      style: TextStyle(
                                        color: Theme.of(context).colorScheme.onPrimary,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            subtitle: null,
                            onTap: isCurrentDevice 
                                ? null 
                                : () {
                                    // 直接连接设备
                                    _showConnectionDialog(device);
                                  },
                            enabled: !isCurrentDevice,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _getDeviceIcon(String deviceName) {
    final name = deviceName.toLowerCase();
    if (name.contains('tv') || name.contains('电视')) {
      return Icons.tv;
    } else if (name.contains('box') || name.contains('盒子')) {
      return Icons.device_hub;
    } else if (name.contains('player') || name.contains('播放器')) {
      return Icons.play_circle_outline;
    } else {
      return Icons.devices_other;
    }
  }

  String _formatTime(DateTime time) {
    final now = DateTime.now();
    final difference = now.difference(time);

    if (difference.inMinutes < 1) {
      return '刚刚';
    } else if (difference.inMinutes < 60) {
      return '${difference.inMinutes}分钟前';
    } else if (difference.inHours < 24) {
      return '${difference.inHours}小时前';
    } else {
      return '${difference.inDays}天前';
    }
  }

  void _showConnectionDialog(DLNADevice device) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('投屏'),
        content: Text('正在投屏到 ${device.info.friendlyName}...'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
        ],
      ),
    );

    // 执行投屏操作
    _castToDevice(device);
  }

  void _castToDevice(DLNADevice device) async {
    try {
      // 构建标题：{title} - {第 x 集} - {sourceName}
      // 如果总集数为 1，则不显示集数
      String formattedTitle = widget.videoTitle ?? '视频';
      if (widget.sourceName != null) {
        if (widget.totalEpisodes != null && widget.totalEpisodes! > 1 && widget.currentEpisodeIndex != null) {
          final episodeNumber = widget.currentEpisodeIndex! + 1;
          formattedTitle = '${widget.videoTitle} - 第 $episodeNumber 集 - ${widget.sourceName}';
        } else {
          formattedTitle = '${widget.videoTitle} - ${widget.sourceName}';
        }
      }
      
      // 设置设备URL并播放
      debugPrint('widget.currentUrl: ${widget.currentUrl}');
      debugPrint('formattedTitle: $formattedTitle');
      debugPrint('widget.resumePosition: ${widget.resumePosition?.inSeconds ?? 0}秒');
      device.setUrl(widget.currentUrl, title: formattedTitle);
      device.play();

      if (mounted) {
        Navigator.of(context).pop(); // 关闭连接对话框
        Navigator.of(context).pop(); // 关闭设备选择对话框

        // 通知父组件投屏已开始，传递设备对象
        widget.onCastStarted?.call(device);
      }
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop(); // 关闭连接对话框

        // 显示投屏失败提示
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('投屏失败: $e'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }
}
