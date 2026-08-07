import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:luna_tv/utils/text_context_menu.dart';
import 'dart:convert';
import 'dart:async';
import 'package:luna_tv/services/user_data_service.dart';
import 'package:luna_tv/services/local_mode_storage_service.dart';
import 'package:luna_tv/services/subscription_service.dart';
import 'package:luna_tv/services/theme_service.dart';
import 'package:luna_tv/utils/device_utils.dart';
import 'package:provider/provider.dart';
import 'package:luna_tv/screens/home_screen.dart';

/// LunaTV 风格登录页
/// 主色：emerald-500 (LunaTV Web 绿色品牌色)
class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _subscriptionUrlController = TextEditingController();
  bool _isPasswordVisible = false;
  bool _isLoading = false;
  bool _isFormValid = false;
  bool _isLocalMode = false;

  int _logoTapCount = 0;
  Timer? _tapTimer;

  @override
  void initState() {
    super.initState();
    _urlController.addListener(_validateForm);
    _usernameController.addListener(_validateForm);
    _passwordController.addListener(_validateForm);
    _subscriptionUrlController.addListener(_validateForm);
    _loadSavedUserData();
  }

  void _loadSavedUserData() async {
    final userData = await UserDataService.getAllUserData();
    if (!mounted) return;

    bool hasData = false;

    if (userData['serverUrl'] != null) {
      _urlController.text = userData['serverUrl']!;
      hasData = true;
    }
    if (userData['username'] != null) {
      _usernameController.text = userData['username']!;
      hasData = true;
    }
    if (userData['password'] != null) {
      _passwordController.text = userData['password']!;
      hasData = true;
    }

    final subscriptionUrl = await LocalModeStorageService.getSubscriptionUrl();
    if (!mounted) return;

    if (subscriptionUrl != null && subscriptionUrl.isNotEmpty) {
      _subscriptionUrlController.text = subscriptionUrl;
      hasData = true;
    }

    if (hasData && mounted) {
      _validateForm();
    }
  }

  @override
  void dispose() {
    _urlController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    _subscriptionUrlController.dispose();
    _tapTimer?.cancel();
    super.dispose();
  }

  void _handleLogoTap() {
    _logoTapCount++;
    _tapTimer?.cancel();

    if (_logoTapCount >= 10) {
      setState(() {
        _isLocalMode = !_isLocalMode;
        _validateForm();
        _logoTapCount = 0;
      });
      _showToast(
        _isLocalMode ? '已切换到本地模式' : '已切换到服务器模式',
        AppColors.primary,
      );
    } else {
      _tapTimer = Timer(const Duration(seconds: 1), () {
        if (!mounted) return;
        setState(() {
          _logoTapCount = 0;
        });
      });
    }
  }

  void _validateForm() {
    if (!mounted) return;

    setState(() {
      if (_isLocalMode) {
        _isFormValid = _subscriptionUrlController.text.isNotEmpty;
      } else {
        _isFormValid = _urlController.text.isNotEmpty &&
            _usernameController.text.isNotEmpty &&
            _passwordController.text.isNotEmpty;
      }
    });
  }

  void _handleSubmit() {
    if (_isLocalMode) {
      _handleLocalModeLogin();
    } else {
      _handleLogin();
    }
  }

  String _processUrl(String url) {
    String processedUrl = url.trim();
    if (processedUrl.endsWith('/')) {
      processedUrl = processedUrl.substring(0, processedUrl.length - 1);
    }
    return processedUrl;
  }

  String _parseCookies(http.Response response) {
    List<String> cookies = [];
    final setCookieHeaders = response.headers['set-cookie'];
    if (setCookieHeaders != null) {
      final cookieParts = setCookieHeaders.split(';');
      if (cookieParts.isNotEmpty) {
        cookies.add(cookieParts[0].trim());
      }
    }
    return cookies.join('; ');
  }

  void _showToast(String message, Color backgroundColor) {
    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          message,
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        backgroundColor: backgroundColor,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        margin: const EdgeInsets.all(16),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _handleLogin() async {
    if (_formKey.currentState!.validate() && _isFormValid) {
      setState(() {
        _isLoading = true;
      });

      try {
        String baseUrl = _processUrl(_urlController.text);
        String loginUrl = '$baseUrl/api/login';

        final response = await http.post(
          Uri.parse(loginUrl),
          headers: {
            'Content-Type': 'application/json',
          },
          body: json.encode({
            'username': _usernameController.text,
            'password': _passwordController.text,
          }),
        );
        if (!mounted) return;

        setState(() {
          _isLoading = false;
        });

        switch (response.statusCode) {
          case 200:
            String cookies = _parseCookies(response);
            await UserDataService.saveUserData(
              serverUrl: baseUrl,
              username: _usernameController.text,
              password: _passwordController.text,
              cookies: cookies,
            );
            if (!mounted) return;

            await UserDataService.saveIsLocalMode(false);
            if (!mounted) return;

            if (mounted) {
              Navigator.of(context).pushAndRemoveUntil(
                MaterialPageRoute(builder: (context) => const HomeScreen()),
                (route) => false,
              );
            }
            break;
          case 401:
            _showToast('用户名或密码错误', const Color(0xFFEF4444));
            break;
          case 500:
            _showToast('服务器错误', const Color(0xFFEF4444));
            break;
          default:
            _showToast('网络异常', const Color(0xFFEF4444));
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });
        _showToast('网络异常', const Color(0xFFEF4444));
      }
    }
  }

  void _handleLocalModeLogin() async {
    if (_formKey.currentState!.validate()) {
      setState(() {
        _isLoading = true;
      });

      try {
        final newUrl = _subscriptionUrlController.text.trim();

        final response = await http.get(Uri.parse(newUrl));
        if (!mounted) return;

        if (response.statusCode != 200) {
          setState(() {
            _isLoading = false;
          });
          _showToast('获取订阅内容失败', const Color(0xFFEF4444));
          return;
        }

        final content =
            await SubscriptionService.parseSubscriptionContent(response.body);
        if (!mounted) return;

        if (content == null ||
            content.searchResources == null ||
            content.searchResources!.isEmpty) {
          setState(() {
            _isLoading = false;
          });
          _showToast('解析订阅内容失败', const Color(0xFFEF4444));
          return;
        }

        final existingUrl = await LocalModeStorageService.getSubscriptionUrl();
        if (!mounted) return;

        if (existingUrl != null &&
            existingUrl.isNotEmpty &&
            existingUrl != newUrl) {
          setState(() {
            _isLoading = false;
          });

          if (!mounted) return;

          final shouldClear = await showDialog<bool>(
            context: context,
            builder: (context) => AlertDialog(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16)),
              title: const Text('提示'),
              content: const Text(
                  '检测到已有本地模式内容且订阅链接不一致,是否清空全部本地模式存储?'),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('否'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text(
                    '是',
                    style: TextStyle(color: Color(0xFFEF4444)),
                  ),
                ),
              ],
            ),
          );
          if (!mounted) return;

          if (shouldClear == true) {
            await LocalModeStorageService.clearAllLocalModeData();
            if (!mounted) return;
          } else if (shouldClear == null) {
            return;
          }

          setState(() {
            _isLoading = true;
          });
        }

        await LocalModeStorageService.saveSubscriptionUrl(newUrl);
        if (!mounted) return;
        if (content.searchResources != null &&
            content.searchResources!.isNotEmpty) {
          await LocalModeStorageService.saveSearchSources(
              content.searchResources!);
          if (!mounted) return;
        }

        await UserDataService.saveIsLocalMode(true);
        if (!mounted) return;

        setState(() {
          _isLoading = false;
        });

        if (mounted) {
          Navigator.of(context).pushAndRemoveUntil(
            MaterialPageRoute(builder: (context) => const HomeScreen()),
            (route) => false,
          );
        }
      } catch (e) {
        if (!mounted) return;
        setState(() {
          _isLoading = false;
        });
        _showToast('登录失败:${e.toString()}', const Color(0xFFEF4444));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isDarkMode = context.watch<ThemeService>().isDarkMode;
    final isTablet = DeviceUtils.isTablet(context);

    return Scaffold(
      body: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isDarkMode
                ? const [
                    Color(0xFF111827),
                    Color(0xFF000000),
                    Color(0xFF111827),
                  ]
                : const [
                    Color(0xFFECFDF5), // emerald-50
                    Color(0xFFFFFFFF),
                    Color(0xFFF0FDFA), // teal-50
                  ],
          ),
        ),
        child: Stack(
          children: [
            // 装饰光斑 (LunaTV 风格)
            Positioned(
              top: MediaQuery.of(context).size.height * 0.15,
              left: MediaQuery.of(context).size.width * 0.1,
              child: _buildBlurCircle(
                isDarkMode
                    ? const Color(0xFF10B981).withOpacity(0.18)
                    : const Color(0xFF6EE7B7).withOpacity(0.5),
                180,
              ),
            ),
            Positioned(
              bottom: MediaQuery.of(context).size.height * 0.2,
              right: MediaQuery.of(context).size.width * 0.15,
              child: _buildBlurCircle(
                isDarkMode
                    ? const Color(0xFF14B8A6).withOpacity(0.18)
                    : const Color(0xFF5EEAD4).withOpacity(0.45),
                180,
              ),
            ),
            Positioned(
              top: MediaQuery.of(context).size.height * 0.45,
              left: MediaQuery.of(context).size.width * 0.5,
              child: _buildBlurCircle(
                isDarkMode
                    ? const Color(0xFF34D399).withOpacity(0.12)
                    : const Color(0xFFA7F3D0).withOpacity(0.4),
                160,
              ),
            ),

            // 登录卡片
            SafeArea(
              child: Center(
                child: SingleChildScrollView(
                  padding: EdgeInsets.symmetric(
                    horizontal: isTablet ? 0 : 16.0,
                    vertical: 24.0,
                  ),
                  child: Container(
                    constraints: const BoxConstraints(maxWidth: 420),
                    padding: const EdgeInsets.all(24),
                    decoration: BoxDecoration(
                      color: isDarkMode
                          ? Colors.white.withOpacity(0.05)
                          : Colors.white.withOpacity(0.85),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: isDarkMode
                            ? Colors.white.withOpacity(0.1)
                            : Colors.white.withOpacity(0.5),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF10B981).withOpacity(0.12),
                          blurRadius: 32,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: Form(
                      key: _formKey,
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Logo + 站名
                          _buildLogoHeader(isDarkMode),
                          const SizedBox(height: 32),

                          // 表单
                          _isLocalMode
                              ? _buildSubscriptionForm(isDarkMode)
                              : _buildServerForm(isDarkMode),

                          const SizedBox(height: 24),

                          // 登录按钮
                          _buildLoginButton(isDarkMode),

                          const SizedBox(height: 16),

                          // 模式切换提示
                          if (_isLocalMode)
                            Text(
                              '本地模式',
                              style: TextStyle(
                                fontSize: 12,
                                color: isDarkMode
                                    ? AppColors.darkTextSecondary
                                    : AppColors.lightTextSecondary,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBlurCircle(Color color, double size) {
    return IgnorePointer(
      child: Container(
        width: size * 2,
        height: size * 2,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          boxShadow: [
            BoxShadow(
              color: color,
              blurRadius: 80,
              spreadRadius: 40,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildLogoHeader(bool isDarkMode) {
    return GestureDetector(
      onTap: _handleLogoTap,
      child: Column(
        children: [
          // Logo (LunaTV 风格: 绿色渐变方块 + 闪光图标)
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [Color(0xFF22C55E), Color(0xFF059669)],
              ),
              borderRadius: BorderRadius.circular(16),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF22C55E).withOpacity(0.4),
                  blurRadius: 20,
                  offset: const Offset(0, 6),
                ),
              ],
            ),
            child: const Icon(
              Icons.auto_awesome,
              color: Colors.white,
              size: 32,
            ),
          ),
          const SizedBox(height: 16),
          // 标题 (LunaTV 绿色渐变)
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [Color(0xFF16A34A), Color(0xFF0D9488)],
            ).createShader(bounds),
            child: const Text(
              'LunaTV',
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: Colors.white,
                letterSpacing: -0.5,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            '欢迎回来，请登录您的账户',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w500,
              color: isDarkMode
                  ? AppColors.darkTextSecondary
                  : AppColors.lightTextSecondary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildServerForm(bool isDarkMode) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInputField(
          controller: _urlController,
          label: '服务器地址',
          hint: 'https://example.com',
          icon: Icons.link,
          isDarkMode: isDarkMode,
          validator: (value) {
            if (value == null || value.isEmpty) return '请输入服务器地址';
            final uri = Uri.tryParse(value);
            if (uri == null || uri.scheme.isEmpty || uri.host.isEmpty) {
              return '请输入有效的URL地址';
            }
            return null;
          },
        ),
        const SizedBox(height: 16),
        _buildInputField(
          controller: _usernameController,
          label: '用户名',
          hint: '请输入用户名',
          icon: Icons.person_outline,
          isDarkMode: isDarkMode,
          validator: (value) {
            if (value == null || value.isEmpty) return '请输入用户名';
            return null;
          },
        ),
        const SizedBox(height: 16),
        _buildInputField(
          controller: _passwordController,
          label: '密码',
          hint: '请输入密码',
          icon: Icons.lock_outline,
          isDarkMode: isDarkMode,
          isPassword: true,
          onTogglePassword: () {
            setState(() {
              _isPasswordVisible = !_isPasswordVisible;
            });
          },
          isPasswordVisible: _isPasswordVisible,
          validator: (value) {
            if (value == null || value.isEmpty) return '请输入密码';
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildSubscriptionForm(bool isDarkMode) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildInputField(
          controller: _subscriptionUrlController,
          label: '订阅链接',
          hint: '请输入订阅链接',
          icon: Icons.link,
          isDarkMode: isDarkMode,
          validator: (value) {
            if (value == null || value.isEmpty) return '请输入订阅链接';
            return null;
          },
        ),
      ],
    );
  }

  Widget _buildInputField({
    required TextEditingController controller,
    required String label,
    required String hint,
    required IconData icon,
    required bool isDarkMode,
    bool isPassword = false,
    bool isPasswordVisible = false,
    VoidCallback? onTogglePassword,
    String? Function(String?)? validator,
  }) {
    final focusedBorderColor = AppColors.primary;
    return TextFormField(
      controller: controller,
      contextMenuBuilder: chineseTextSelectionToolbarBuilder,
      obscureText: isPassword && !isPasswordVisible,
      style: TextStyle(
        fontSize: 15,
        color: isDarkMode ? AppColors.darkText : AppColors.lightText,
      ),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: Icon(
          icon,
          color: isDarkMode
              ? AppColors.darkTextMuted
              : AppColors.lightTextMuted,
          size: 20,
        ),
        suffixIcon: isPassword
            ? IconButton(
                icon: Icon(
                  isPasswordVisible
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  color: isDarkMode
                      ? AppColors.darkTextMuted
                      : AppColors.lightTextMuted,
                  size: 20,
                ),
                onPressed: onTogglePassword,
              )
            : null,
        filled: true,
        fillColor: isDarkMode
            ? Colors.white.withOpacity(0.05)
            : Colors.white.withOpacity(0.7),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(
            color: isDarkMode
                ? Colors.white.withOpacity(0.1)
                : Colors.black.withOpacity(0.05),
          ),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide(color: focusedBorderColor, width: 2),
        ),
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
      ),
      validator: validator,
      onFieldSubmitted: (_) => _handleSubmit(),
    );
  }

  Widget _buildLoginButton(bool isDarkMode) {
    return Container(
      width: double.infinity,
      height: 48,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF16A34A), Color(0xFF059669)],
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF22C55E).withOpacity(0.35),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ElevatedButton(
        onPressed: (_isLoading || !_isFormValid) ? null : _handleSubmit,
        style: ElevatedButton.styleFrom(
          backgroundColor: Colors.transparent,
          shadowColor: Colors.transparent,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        child: _isLoading
            ? const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    height: 18,
                    width: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor:
                          AlwaysStoppedAnimation<Color>(Colors.white),
                    ),
                  ),
                  SizedBox(width: 12),
                  Text('登录中...',
                      style: TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w600)),
                ],
              )
            : const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.lock_outline, color: Colors.white, size: 18),
                  SizedBox(width: 8),
                  Text(
                    '立即登录',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                ],
              ),
      ),
    );
  }
}
