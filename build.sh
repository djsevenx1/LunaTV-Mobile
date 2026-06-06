#!/bin/bash

# LunaTV 构建脚本
# 用于构建安卓和 iOS 无签名版本，并将构建产物复制到根目录下

set -e  # 遇到错误时退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 版本信息
APP_VERSION=""

# 读取版本号
read_version() {
    log_info "读取项目版本号..."
    
    # 从 pubspec.yaml 中提取版本号
    if [ -f "pubspec.yaml" ]; then
        APP_VERSION=$(grep "^version:" pubspec.yaml | sed 's/version: *//' | tr -d ' ')
        if [ -z "$APP_VERSION" ]; then
            log_error "无法从 pubspec.yaml 中读取版本号"
            exit 1
        fi
        APP_VERSION=$(echo "$APP_VERSION" | cut -d'+' -f1)
        if [ -z "$APP_VERSION" ]; then
            log_error "无法从 pubspec.yaml 中读取版本号"
            exit 1
        fi
        log_success "项目版本号: $APP_VERSION"
    else
        log_error "pubspec.yaml 文件不存在"
        exit 1
    fi
}

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# 检查 Flutter 环境
check_flutter() {
    log_info "检查 Flutter 环境..."
    if ! command -v flutter &> /dev/null; then
        log_error "Flutter 未安装或未添加到 PATH"
        exit 1
    fi
    
    flutter --version
    log_success "Flutter 环境检查通过"
}

# 清理之前的构建
clean_build() {
    log_info "清理之前的构建..."
    flutter clean
    
    # 清理自定义构建目录
    rm -rf ios-build
    rm -rf dist
    rm -rf build-arm64
    rm -rf build-x86_64
    
    log_success "构建清理完成"
}

# 获取依赖
get_dependencies() {
    log_info "获取项目依赖..."
    flutter pub get
    log_success "依赖获取完成"
}

# 构建安卓版本
build_android() {
    log_info "开始构建安卓 armv8 和 armv7a 版本..."
    
    # 确保安卓构建目录存在
    mkdir -p build/android
    
    # 构建 APK，添加优化参数
    flutter build apk --release \
        --target-platform android-arm64,android-arm \
        --split-per-abi \
        --obfuscate \
        --split-debug-info=build/app/outputs/symbols
    
    log_success "安卓构建完成"
}

# 构建 macOS ARM64 版本
build_macos_arm64() {
    log_info "构建 macOS ARM64 版本..."
    
    # 检查是否在 macOS 上
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_warning "macOS 构建只能在 macOS 上进行，跳过 macOS ARM64 构建"
        return
    fi
    
    # 创建独立的构建目录
    mkdir -p build-arm64/macos
    
    # 复制必要的文件到独立目录
    rsync -a --exclude='build*' --exclude='.dart_tool' . build-arm64/
    
    cd build-arm64
    
    # 构建 ARM64 版本
    flutter build macos --release --dart-define=FLUTTER_TARGET_PLATFORM=darwin-arm64
    
    # 备份 ARM64 构建产物
    if [ -d "build/macos/Build/Products/Release/LunaTV.app" ]; then
        mkdir -p ../build/macos-arm64
        ditto build/macos/Build/Products/Release/LunaTV.app ../build/macos-arm64/LunaTV.app
        log_success "macOS ARM64 构建完成"
    fi
    
    cd ..
}

# 构建 macOS x86_64 版本
build_macos_x86_64() {
    log_info "构建 macOS x86_64 版本..."
    
    # 检查是否在 macOS 上
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_warning "macOS 构建只能在 macOS 上进行，跳过 macOS x86_64 构建"
        return
    fi
    
    # 创建独立的构建目录
    mkdir -p build-x86_64/macos
    
    # 复制必要的文件到独立目录
    rsync -a --exclude='build*' --exclude='.dart_tool' . build-x86_64/
    
    cd build-x86_64
    
    # 构建 x86_64 版本
    flutter build macos --release --dart-define=FLUTTER_TARGET_PLATFORM=darwin-x64
    
    # 备份 x86_64 构建产物
    if [ -d "build/macos/Build/Products/Release/LunaTV.app" ]; then
        mkdir -p ../build/macos-x86_64
        ditto build/macos/Build/Products/Release/LunaTV.app ../build/macos-x86_64/LunaTV.app
        log_success "macOS x86_64 构建完成"
    fi
    
    cd ..
}

# 构建 macOS 版本（顺序模式）
build_macos() {
    log_info "开始构建 macOS ARM64 和 x86_64 版本..."
    
    # 检查是否在 macOS 上
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_warning "macOS 构建只能在 macOS 上进行，跳过 macOS 构建"
        return
    fi
    
    build_macos_arm64
    build_macos_x86_64
    
    log_success "macOS 所有架构构建完成"
}

# 构建 iOS 无签名版本
build_ios() {
    log_info "开始构建 iOS 无签名版本..."
    
    # 检查是否在 macOS 上
    if [[ "$OSTYPE" != "darwin"* ]]; then
        log_warning "iOS 构建只能在 macOS 上进行，跳过 iOS 构建"
        return
    fi
    
    # 确保 iOS 构建目录存在
    mkdir -p build/ios
    
    # 构建 iOS 无签名版本
    flutter build ios --release --no-codesign
    
    # 检查构建是否成功
    if [ ! -d "build/ios/iphoneos/Runner.app" ]; then
        log_error "iOS 应用构建失败"
        return 1
    fi
    
    # 创建 .ipa 文件
    log_info "创建 iOS .ipa 文件..."
    
    # 确保 ios-build 目录存在
    mkdir -p ios-build
    
    cd build/ios/iphoneos
    
    # 创建 Payload 目录
    mkdir -p Payload
    cp -r Runner.app Payload/
    
    # 创建 .ipa 文件
    zip -r "../../../ios-build/Runner.ipa" Payload/
    
    # 清理临时文件
    rm -rf Payload
    
    cd ../../..
    
    log_success "iOS 构建完成"
}

# 复制构建产物到根目录
copy_artifacts() {
    log_info "复制构建产物到根目录..."
    
    # 创建输出目录
    mkdir -p dist
    
    # 复制安卓 APK
    if [ -f "build/app/outputs/flutter-apk/app-arm64-v8a-release.apk" ]; then
        cp build/app/outputs/flutter-apk/app-arm64-v8a-release.apk "dist/LunaTV-${APP_VERSION}-armv8.apk"
        log_success "安卓 arm64 APK 已复制到 dist/LunaTV-${APP_VERSION}-armv8.apk"
    else
        log_warning "安卓 arm64 APK 文件未找到"
    fi
    if [ -f "build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk" ]; then
        cp build/app/outputs/flutter-apk/app-armeabi-v7a-release.apk "dist/LunaTV-${APP_VERSION}-armv7a.apk"
        log_success "安卓 armv7a APK 已复制到 dist/LunaTV-${APP_VERSION}-armv7a.apk"
    else
        log_warning "安卓 armv7a APK 文件未找到"
    fi

    # 复制 iOS 构建产物
    if [ -f "ios-build/Runner.ipa" ]; then
        cp ios-build/Runner.ipa "dist/LunaTV-${APP_VERSION}.ipa"
        log_success "iOS .ipa 文件已复制到 dist/LunaTV-${APP_VERSION}.ipa"
    else
        log_warning "iOS .ipa 文件未找到"
    fi
    
    # 打包 macOS ARM64 应用为 DMG
    if [ -d "build/macos-arm64/LunaTV.app" ]; then
        log_info "打包 macOS ARM64 应用为 DMG..."
        
        DMG_NAME="LunaTV-${APP_VERSION}-macos-arm64.dmg"
        DMG_PATH="dist/${DMG_NAME}"
        
        # 创建临时目录
        TMP_DMG_DIR=$(mktemp -d)
        cp -R build/macos-arm64/LunaTV.app "$TMP_DMG_DIR/"
        
        # 创建 DMG
        hdiutil create -volname "LunaTV" \
            -srcfolder "$TMP_DMG_DIR" \
            -ov -format UDZO \
            "$DMG_PATH"
        
        # 清理临时目录
        rm -rf "$TMP_DMG_DIR"
        
        log_success "macOS ARM64 应用已打包到 ${DMG_PATH}"
    else
        log_warning "macOS ARM64 应用文件未找到"
    fi
    
    # 打包 macOS x86_64 应用为 DMG
    if [ -d "build/macos-x86_64/LunaTV.app" ]; then
        log_info "打包 macOS x86_64 应用为 DMG..."
        
        DMG_NAME="LunaTV-${APP_VERSION}-macos-x86_64.dmg"
        DMG_PATH="dist/${DMG_NAME}"
        
        # 创建临时目录
        TMP_DMG_DIR=$(mktemp -d)
        cp -R build/macos-x86_64/LunaTV.app "$TMP_DMG_DIR/"
        
        # 创建 DMG
        hdiutil create -volname "LunaTV" \
            -srcfolder "$TMP_DMG_DIR" \
            -ov -format UDZO \
            "$DMG_PATH"
        
        # 清理临时目录
        rm -rf "$TMP_DMG_DIR"
        
        log_success "macOS x86_64 应用已打包到 ${DMG_PATH}"
    else
        log_warning "macOS x86_64 应用文件未找到"
    fi
    
    log_success "构建产物复制完成"
}

# 显示构建结果
show_results() {
    log_info "构建结果:"
    echo ""
    
    if [ -d "dist" ]; then
        echo "📁 构建产物目录:"
        ls -la dist/
        echo ""
        
        echo "📊 文件大小:"
        du -h dist/*
        echo ""
        
        log_success "所有构建产物已保存到 dist/ 目录"
    else
        log_warning "未找到构建产物"
    fi
}

# 主函数
main() {
    echo "🚀 LunaTV 构建脚本启动"
    echo "=================================="
    
    # 检查参数
    BUILD_ANDROID=true
    BUILD_IOS=true
    BUILD_MACOS_ARM64=true
    BUILD_MACOS_X86_64=true
    PARALLEL_BUILD=true
    
    while [[ $# -gt 0 ]]; do
        case $1 in
            --android-only)
                BUILD_IOS=false
                BUILD_MACOS_ARM64=false
                BUILD_MACOS_X86_64=false
                shift
                ;;
            --ios-only)
                BUILD_ANDROID=false
                BUILD_MACOS_ARM64=false
                BUILD_MACOS_X86_64=false
                shift
                ;;
            --macos-arm64-only)
                BUILD_ANDROID=false
                BUILD_IOS=false
                BUILD_MACOS_X86_64=false
                shift
                ;;
            --macos-x86_64-only)
                BUILD_ANDROID=false
                BUILD_IOS=false
                BUILD_MACOS_ARM64=false
                shift
                ;;
            --macos-only)
                BUILD_ANDROID=false
                BUILD_IOS=false
                shift
                ;;
            --apple-only)
                BUILD_ANDROID=false
                PARALLEL_BUILD=false
                shift
                ;;
            --sequential)
                PARALLEL_BUILD=false
                shift
                ;;
            --help)
                echo "用法: $0 [选项]"
                echo "选项:"
                echo "  --android-only       只构建 Android 版本"
                echo "  --ios-only           只构建 iOS 版本"
                echo "  --macos-arm64-only   只构建 macOS ARM64 版本"
                echo "  --macos-x86_64-only  只构建 macOS x86_64 版本"
                echo "  --macos-only         构建 macOS 所有架构"
                echo "  --apple-only         构建所有 Apple 平台版本（iOS 和 macOS）"
                echo "  --sequential         顺序构建（默认为并行构建）"
                echo "  --help               显示此帮助信息"
                exit 0
                ;;
            *)
                log_error "未知参数: $1"
                echo "使用 --help 查看帮助信息"
                exit 1
                ;;
        esac
    done
    
    # 执行构建流程
    read_version
    check_flutter
    clean_build
    get_dependencies
    
    # 并行构建模式
    if [ "$PARALLEL_BUILD" = true ]; then
        log_info "启用并行构建模式..."
        
        # 使用后台进程并行构建
        pids=()
        
        if [ "$BUILD_ANDROID" = true ]; then
            build_android &
            pids+=($!)
        fi
        
        if [ "$BUILD_IOS" = true ]; then
            build_ios &
            pids+=($!)
        fi
        
        if [ "$BUILD_MACOS_ARM64" = true ]; then
            build_macos_arm64 &
            pids+=($!)
        fi
        
        if [ "$BUILD_MACOS_X86_64" = true ]; then
            build_macos_x86_64 &
            pids+=($!)
        fi
        
        # 等待所有后台进程完成
        log_info "等待所有构建任务完成..."
        failed=0
        for pid in "${pids[@]}"; do
            if ! wait "$pid"; then
                log_warning "构建进程 $pid 失败"
                failed=1
            fi
        done

        if [ "$failed" -ne 0 ]; then
            log_error "至少一个并行构建任务失败"
            exit 1
        fi
        
        log_success "所有并行构建任务已完成"
    else
        # 顺序构建模式
        if [ "$BUILD_ANDROID" = true ]; then
            build_android
        fi
        
        if [ "$BUILD_IOS" = true ]; then
            build_ios
        fi
        
        if [ "$BUILD_MACOS_ARM64" = true ]; then
            build_macos_arm64
        fi
        
        if [ "$BUILD_MACOS_X86_64" = true ]; then
            build_macos_x86_64
        fi
    fi
    
    copy_artifacts
    show_results
    
    # 清理临时构建目录
    log_info "清理临时构建目录..."
    rm -rf build
    rm -rf build-arm64
    rm -rf build-x86_64
    log_success "临时构建目录已清理"
    
    echo "=================================="
    log_success "构建完成！"
}

# 运行主函数
main "$@"
