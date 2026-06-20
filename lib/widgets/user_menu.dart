import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/screens/login_screen.dart';

/// 极简用户菜单：只显示用户信息和登出按钮
class UserMenu extends StatefulWidget {
  final bool isDarkMode;
  final VoidCallback? onClose;

  const UserMenu({
    super.key,
    required this.isDarkMode,
    this.onClose,
  });

  @override
  State<UserMenu> createState() => _UserMenuState();
}

class _UserMenuState extends State<UserMenu> {
  String? _username;
  String _role = 'user';
  bool _isLocalMode = false;

  @override
  void initState() {
    super.initState();
    _loadUserInfo();
  }

  Future<void> _loadUserInfo() async {
    final isLocalMode = await UserDataService.getIsLocalMode();
    final username = await UserDataService.getUsername();
    final cookies = await UserDataService.getCookies();

    if (!mounted) return;
    setState(() {
      _isLocalMode = isLocalMode;
      _username = username;
      _role = _parseRoleFromCookies(cookies);
    });
  }

  String _parseRoleFromCookies(String? cookies) {
    if (cookies == null || cookies.isEmpty) return 'user';

    try {
      final cookieMap = <String, String>{};
      final cookiePairs = cookies.split(';');

      for (final cookie in cookiePairs) {
        final trimmed = cookie.trim();
        final firstEqualIndex = trimmed.indexOf('=');

        if (firstEqualIndex > 0) {
          final key = trimmed.substring(0, firstEqualIndex);
          final value = trimmed.substring(firstEqualIndex + 1);
          if (key.isNotEmpty && value.isNotEmpty) {
            cookieMap[key] = value;
          }
        }
      }

      final authCookie = cookieMap['auth'];
      if (authCookie == null) return 'user';

      String decoded = Uri.decodeComponent(authCookie);
      if (decoded.contains('%')) {
        decoded = Uri.decodeComponent(decoded);
      }

      final authData = json.decode(decoded);
      final role = authData['role'] as String?;
      return role ?? 'user';
    } catch (e) {
      return 'user';
    }
  }

  Future<void> _handleLogout() async {
    await UserDataService.clearPasswordAndCookies();
    await UserDataService.saveIsLocalMode(false);

    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (context) => const LoginScreen()),
      (route) => false,
    );
  }

  Widget _buildRoleTag() {
    String label;
    Color color;

    switch (_role) {
      case 'admin':
        label = '管理员';
        color = const Color(0xFFf59e0b);
        break;
      case 'owner':
        label = '站长';
        color = const Color(0xFF8b5cf6);
        break;
      case 'user':
      default:
        label = '用户';
        color = const Color(0xFF10b981);
        break;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 10,
          color: Colors.white,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: GestureDetector(
        onTap: widget.onClose,
        child: Container(
          color: Colors.black.withOpacity(0.3),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 260,
                margin: const EdgeInsets.symmetric(horizontal: 20),
                decoration: BoxDecoration(
                  color: widget.isDarkMode
                      ? const Color(0xFF2c2c2c)
                      : Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withOpacity(0.1),
                      blurRadius: 20,
                      offset: const Offset(0, 8),
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 用户信息区域
                    Padding(
                      padding: const EdgeInsets.all(20),
                      child: Column(
                        children: [
                          if (!_isLocalMode)
                            Text(
                              '当前用户',
                              style: TextStyle(
                                fontSize: 12,
                                color: widget.isDarkMode
                                    ? const Color(0xFF9ca3af)
                                    : const Color(0xFF6b7280),
                                fontWeight: FontWeight.w400,
                              ),
                            ),
                          if (!_isLocalMode) const SizedBox(height: 8),
                          if (_isLocalMode)
                            Text(
                              '本地模式',
                              style: TextStyle(
                                fontSize: 18,
                                color: widget.isDarkMode
                                    ? const Color(0xFFffffff)
                                    : const Color(0xFF1f2937),
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          else
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Flexible(
                                  child: Text(
                                    _username ?? '未知用户',
                                    style: TextStyle(
                                      fontSize: 18,
                                      color: widget.isDarkMode
                                          ? const Color(0xFFffffff)
                                          : const Color(0xFF1f2937),
                                      fontWeight: FontWeight.w600,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                _buildRoleTag(),
                              ],
                            ),
                        ],
                      ),
                    ),
                    Container(
                      height: 1,
                      color: widget.isDarkMode
                          ? const Color(0xFF374151)
                          : const Color(0xFFe5e7eb),
                    ),
                    // 登出按钮
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: _handleLogout,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 14,
                          ),
                          child: Row(
                            children: const [
                              Icon(
                                LucideIcons.logOut,
                                size: 20,
                                color: Color(0xFFef4444),
                              ),
                              SizedBox(width: 12),
                              Text(
                                '登出',
                                style: TextStyle(
                                  fontSize: 16,
                                  color: Color(0xFFef4444),
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}