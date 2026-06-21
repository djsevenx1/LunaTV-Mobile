"""
LunaTV App 图标生成器
====================
保留 LunaTV 原版月亮背景,把中间人物轮廓替换为绿色播放按钮 (#27AE60)

依赖: pip install Pillow
运行: python3 generate_icon.py
输出: build/icon-1024.png + 各尺寸 iOS/Android 图标
"""
import os
from PIL import Image, ImageDraw

# ============== 配置 ==============
SIZE = 1024  # 主图尺寸
GREEN = (39, 174, 96)            # #27AE60 LunaTV 主题绿
GREEN_LIGHT = (88, 214, 141)     # 高光绿
GREEN_DARK = (30, 130, 70)       # 阴影绿
MOON_COLOR = (215, 220, 230)     # 月亮浅蓝灰
WHITE = (255, 255, 255)
TRANSPARENT = (0, 0, 0, 0)

# iOS AppIcon 需要的尺寸 (px)
IOS_SIZES = [
    (20, 1), (20, 2), (20, 3),
    (29, 1), (29, 2), (29, 3),
    (40, 1), (40, 2), (40, 3),
    (50, 1), (50, 2),
    (57, 1), (57, 2),
    (60, 2), (60, 3),
    (72, 1), (72, 2),
    (76, 1), (76, 2),
    (83.5, 2),
    (1024, 1),
]

# Android mipmap 密度对应的尺寸
ANDROID_SIZES = {
    'mipmap-mdpi': 48,
    'mipmap-hdpi': 72,
    'mipmap-xhdpi': 96,
    'mipmap-xxhdpi': 144,
    'mipmap-xxxhdpi': 192,
}


# ============== 绘制函数 ==============
def draw_icon(size: int = 1024) -> Image.Image:
    """绘制单个图标,返回 RGBA Image"""
    img = Image.new('RGBA', (size, size), TRANSPARENT)
    draw = ImageDraw.Draw(img)

    # 缩放因子(所有元素按 1024 基准缩放)
    s = size / 1024

    # 1. 白色圆角方形背景 (iOS 风格圆角)
    radius = int(180 * s)
    draw.rounded_rectangle(
        [(0, 0), (size, size)],
        radius=radius,
        fill=WHITE + (255,),
    )

    # 2. 月亮背景 (浅蓝灰新月,开口朝下,月亮在上方)
    moon_color = MOON_COLOR + (255,)
    # 月亮主体圆 - 偏上方
    draw.ellipse(
        [(int(180 * s), int(80 * s)), (int(860 * s), int(760 * s))],
        fill=moon_color,
    )
    # 挖出下方形成新月(开口朝下)
    draw.ellipse(
        [(int(260 * s), int(380 * s)), (int(940 * s), int(1060 * s))],
        fill=WHITE + (255,),
    )

    # 3. 绿色播放按钮圆形 (中心,缩小)
    cx = size // 2
    cy = size // 2 + int(40 * s)
    r_circle = int(170 * s)  # 从 220 缩小到 170

    # 外圈柔光晕
    for i in range(10):
        alpha = max(0, 45 - i * 4)
        draw.ellipse(
            [(cx - r_circle - i * 2, cy - r_circle - i * 2),
             (cx + r_circle + i * 2, cy + r_circle + i * 2)],
            fill=GREEN + (alpha,),
        )

    # 主圆
    draw.ellipse(
        [(cx - r_circle, cy - r_circle), (cx + r_circle, cy + r_circle)],
        fill=GREEN + (255,),
    )

    # 内圈高光边
    draw.ellipse(
        [(cx - r_circle + int(12 * s), cy - r_circle + int(12 * s)),
         (cx + r_circle - int(12 * s), cy + r_circle - int(12 * s))],
        outline=GREEN_LIGHT + (200,),
        width=max(2, int(4 * s)),
    )

    # 4. 白色播放三角形 (缩小)
    tri_size = int(95 * s)  # 从 130 缩小到 95
    tx = cx + int(22 * s)  # 视觉居中向右偏移
    ty = cy
    triangle = [
        (tx - tri_size // 2, ty - tri_size // 2),
        (tx - tri_size // 2, ty + tri_size // 2),
        (tx + tri_size // 2 + int(15 * s), ty),
    ]
    draw.polygon(triangle, fill=WHITE + (255,))

    return img


# ============== 输出函数 ==============
def build_all(output_dir: str = 'build'):
    """生成所有尺寸的图标到指定目录"""
    os.makedirs(output_dir, exist_ok=True)

    # 1. 主 1024 图标
    main_icon = draw_icon(1024)
    main_path = os.path.join(output_dir, 'icon-1024.png')
    main_icon.save(main_path, 'PNG')
    print(f'✓ {main_path}')

    # 2. iOS 各尺寸
    ios_dir = os.path.join(output_dir, 'ios', 'AppIcon.appiconset')
    os.makedirs(ios_dir, exist_ok=True)
    for base_size, scale in IOS_SIZES:
        px = int(base_size * scale)
        icon = draw_icon(px)
        name = f'Icon-App-{base_size}x{base_size}@{scale}x.png'
        path = os.path.join(ios_dir, name)
        icon.save(path, 'PNG')
        print(f'✓ {path}')

    # 3. Android 各密度
    for density, px in ANDROID_SIZES.items():
        d = os.path.join(output_dir, 'android', density)
        os.makedirs(d, exist_ok=True)
        icon = draw_icon(px)
        for name in ['ic_launcher.png', 'launcher_icon.png']:
            path = os.path.join(d, name)
            icon.save(path, 'PNG')
            print(f'✓ {path}')

    print(f'\n全部生成完毕,目录: {output_dir}/')


# ============== 入口 ==============
if __name__ == '__main__':
    build_all('build')
