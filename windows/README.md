# Windows 安装包构建说明

本项目使用 Inno Setup 创建 Windows 安装程序。

## 前置要求

1. **Inno Setup 6**
   - 下载地址: https://jrsoftware.org/isdl.php
   - 安装到默认路径（推荐）: `C:\Program Files (x86)\Inno Setup 6\`

2. **Flutter 环境**
   - 确保已正确安装 Flutter SDK
   - 确保已配置 Windows 桌面开发环境

## 构建步骤

### 方法 1: 使用构建脚本（推荐）

在 Git Bash 或 MSYS2 中运行：

```bash
# 构建 Windows 版本和安装包
./build.sh --windows-only

# 或者构建所有平台
./build.sh
```

构建完成后，你会在 `dist/` 目录下找到：
- `LunaTV-{version}-windows-x64-portable.zip` - 便携版（解压即用）
- `LunaTV-{version}-windows-x64-setup.exe` - 安装程序

### 方法 2: 手动构建

```bash
# 1. 构建 Flutter Windows 应用
flutter build windows --release

# 2. 编译安装程序
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DMyAppVersion=1.4.3 windows\installer.iss
```

## 自定义安装程序

编辑 `windows/installer.iss` 文件可以自定义：

- **应用信息**: 修改 `MyAppName`, `MyAppPublisher`, `MyAppURL`
- **应用 ID**: 修改 `AppId` (使用 GUID 生成器创建唯一 ID)
- **安装路径**: 修改 `DefaultDirName`
- **图标**: 确保 `logo.ico` 存在，或修改 `SetupIconFile`
- **许可协议**: 取消注释 `LicenseFile` 并指向你的 LICENSE 文件
- **语言**: 在 `[Languages]` 部分添加更多语言支持

## 图标设置

如果你有 `logo.jpg` 但没有 `logo.ico`，可以使用以下工具转换：

### 使用在线工具
- https://convertio.co/jpg-ico/
- https://www.icoconverter.com/

### 使用 ImageMagick
```bash
magick convert logo.jpg -resize 256x256 logo.ico
```

## 常见问题

### 1. 找不到 ISCC.exe
确保 Inno Setup 已正确安装。如果安装在非默认路径，修改 `build.sh` 中的 `ISCC_PATH`。

### 2. 安装程序无法运行
- 检查是否有杀毒软件拦截
- 尝试以管理员身份运行
- 检查 Windows Defender SmartScreen 设置

### 3. 需要代码签名
为了避免 Windows 安全警告，建议购买代码签名证书并签名安装程序：

```bash
signtool sign /f certificate.pfx /p password /t http://timestamp.digicert.com dist/LunaTV-setup.exe
```

## 发布检查清单

- [ ] 更新 `pubspec.yaml` 中的版本号
- [ ] 测试安装程序在干净的 Windows 系统上运行
- [ ] 测试卸载功能
- [ ] 检查快捷方式是否正确创建
- [ ] 验证应用程序可以正常启动
- [ ] 检查文件大小是否合理
- [ ] （可选）对安装程序进行代码签名

## 参考资料

- [Inno Setup 官方文档](https://jrsoftware.org/ishelp/)
- [Flutter Windows 桌面支持](https://docs.flutter.dev/platform-integration/windows/building)
