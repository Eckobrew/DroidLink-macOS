#!/bin/bash
set -e

echo "=== Building Droid Link Universal Binary (Apple Silicon + Intel) for macOS Sequoia+ ==="

cd "$(dirname "$0")"

BUILD_DIR=".build/universal"
APP_BUNDLE="build/Droid Link.app"
APP_BIN="$APP_BUNDLE/Contents/MacOS/DroidLink"
APP_RESOURCES="$APP_BUNDLE/Contents/Resources"

mkdir -p "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_RESOURCES"

# Build for Apple Silicon (arm64)
echo "Building arm64 (Apple Silicon)..."
swift build -c release --triple arm64-apple-macosx15.0

# Build for Intel (x86_64)
echo "Building x86_64 (Intel)..."
swift build -c release --triple x86_64-apple-macosx15.0

ARM64_BIN=".build/arm64-apple-macosx/release/DroidLink"
X86_BIN=".build/x86_64-apple-macosx/release/DroidLink"

echo "Creating Universal Binary via lipo..."
lipo -create "$ARM64_BIN" "$X86_BIN" -output "$APP_BIN"
chmod +x "$APP_BIN"

# Create Info.plist
cat <<EOF > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>DroidLink</string>
    <key>CFBundleIdentifier</key>
    <string>com.droidlink.macos</string>
    <key>CFBundleName</key>
    <string>Droid Link</string>
    <key>CFBundleDisplayName</key>
    <string>Droid Link</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Droid Link uses Bluetooth to communicate with your Android phone and route telephone call audio.</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>Droid Link connects to your Android phone via local Wi-Fi with end-to-end encryption.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>Droid Link uses your microphone for phone calls through your Android handset.</string>
</dict>
</plist>
EOF

# Bundle AppIcon
if [ -f "Resources/AppIcon.icns" ]; then
    echo "Bundling AppIcon.icns..."
    cp "Resources/AppIcon.icns" "$APP_RESOURCES/AppIcon.icns"
fi

# Bundle embedded scrcpy and adb
if [ -d "Resources/scrcpy" ]; then
    echo "Bundling embedded scrcpy..."
    mkdir -p "$APP_RESOURCES/scrcpy"
    cp -r Resources/scrcpy/* "$APP_RESOURCES/scrcpy/"
    chmod +x "$APP_RESOURCES/scrcpy/scrcpy" "$APP_RESOURCES/scrcpy/adb"
fi

echo "Signing app bundle ad-hoc..."
codesign -s - --force --deep "$APP_BUNDLE"

# Provide compatibility symlink
cd build
rm -rf "DroidDock.app" "DroidLink.app"
ln -s "Droid Link.app" "DroidLink.app"
cd ..

echo "Verifying Universal Binary architecture..."
lipo -info "$APP_BIN"

echo "=== Successfully built $APP_BUNDLE ==="
