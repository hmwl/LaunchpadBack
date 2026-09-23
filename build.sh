#!/bin/bash
# 构建 启动台.app ；--install 安装到 /Applications 并启动；--dist 生成给别人用的通用版 zip
# 直接调用 swiftc（不依赖 SwiftPM，避免命令行工具版本不匹配导致的 manifest 链接错误）
set -euo pipefail
cd "$(dirname "$0")"

if ! command -v xcrun >/dev/null 2>&1; then
  echo "未找到命令行工具，请先运行: xcode-select --install"; exit 1
fi

SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
MODE="${1:-}"
mkdir -p build
compile() {  # $1 = arch, $2 = output
  echo "▶︎ swiftc ($1), SDK $(xcrun --sdk macosx --show-sdk-version) …"
  xcrun swiftc -O -parse-as-library -swift-version 5 \
    -sdk "$SDK" -target "$1-apple-macos14.0" \
    -framework AppKit -framework SwiftUI -framework Carbon -framework ServiceManagement -framework CoreImage \
    Sources/LaunchpadBack/*.swift \
    -o "$2"
}
if [[ "$MODE" == "--dist" ]]; then
  # 通用二进制：Apple 芯片 + Intel 都能运行
  compile arm64 "build/启动台-arm64"
  compile x86_64 "build/启动台-x86_64"
  lipo -create "build/启动台-arm64" "build/启动台-x86_64" -output "build/启动台"
else
  compile "$ARCH" "build/启动台"
fi

APP="build/启动台.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "build/启动台" "$APP/Contents/MacOS/启动台"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null
echo "✅ 已生成 $APP"

if [[ "$MODE" == "--dist" ]]; then
  rm -f "build/启动台.zip"
  ditto -c -k --keepParent "$APP" "build/启动台.zip"
  echo "✅ 分发包: build/启动台.zip（通用二进制，macOS 14+）"
fi

if [[ "$MODE" == "--install" ]]; then
  pkill -x 启动台 2>/dev/null || true
  rm -rf "/Applications/启动台.app"
  cp -R "$APP" /Applications/
  touch "/Applications/启动台.app"
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/启动台.app" 2>/dev/null || true
  open "/Applications/启动台.app"
  echo "✅ 已安装到 /Applications 并启动"
fi
