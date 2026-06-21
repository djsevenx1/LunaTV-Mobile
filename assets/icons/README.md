# 应用图标（App Launcher Icon）

这里放 **1024×1024 的 PNG 源图**，工具会自动生成所有平台、全部 DPI 的图标资源。

## 用法

1. 把你的图标源图命名为 `app_icon.png`，放到本目录：
   ```
   assets/icons/app_icon.png   (1024x1024, 无透明或纯白底)
   ```

2. 生成所有平台的图标（Android mipmap + iOS AppIcon）：
   ```bash
   flutter pub get
   dart run flutter_launcher_icons
   ```

3. 重启 App 即可看到新图标。

## 设计建议（LunaTV 主题）

| 元素 | 建议 |
|---|---|
| 主色 | 紫色渐变（#6366F1 → #8B5CF6）或绿黑渐变（#10B981 → #059669） |
| 主图形 | 月牙 + TV 边框 / 月亮 + 播放按钮 / "L" 字标 |
| 风格 | 现代扁平 + 微玻璃拟态 + 圆角 |
| 尺寸 | 1024×1024 PNG，圆角不要提前做（系统会裁） |
| 背景 | 实色或渐变，不要复杂纹理（缩到 48×48 时会糊） |

## 快速生成图标

可用 AI 工具生成 1024×1024 源图：
- **ChatGPT / DALL·E**：prompt 参考 "app launcher icon, modern flat design, moon and TV, purple gradient background, rounded square, no text"
- **即梦 / Midjourney / Stable Diffusion**：同上 prompt
- **Figma / Sketch**：手画 1024×1024

## 不用工具直接替换

如果想跳过 `flutter_launcher_icons`，手动把 PNG 放到：
```
android/app/src/main/res/mipmap-mdpi/ic_launcher.png      (48×48)
android/app/src/main/res/mipmap-hdpi/ic_launcher.png      (72×72)
android/app/src/main/res/mipmap-xhdpi/ic_launcher.png     (96×96)
android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png    (144×144)
android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png   (192×192)
```