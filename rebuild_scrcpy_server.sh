#!/usr/bin/env bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SDK_DIR="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
SERVER_BUILD_DIR="$(mktemp -d /tmp/droiddock-scrcpy-server.XXXXXX)"
trap 'rm -rf "$SERVER_BUILD_DIR"' EXIT
(
    cd "$PROJECT_DIR/Vendor/scrcpy/server"
    env ANDROID_HOME="$SDK_DIR" ANDROID_PLATFORM="${ANDROID_PLATFORM:-35}" \
        ANDROID_BUILD_TOOLS="${ANDROID_BUILD_TOOLS:-35.0.0}" BUILD_DIR="$SERVER_BUILD_DIR" \
        bash build_without_gradle.sh
)
cp "$SERVER_BUILD_DIR/scrcpy-server" "$PROJECT_DIR/Resources/scrcpy/scrcpy-server"
echo "Updated bundled scrcpy 5.0.1 server with Android 17 desktop compatibility."
