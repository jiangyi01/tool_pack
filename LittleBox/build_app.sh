#!/bin/bash
# Build LittleBox.app without Xcode: universal binary (Apple silicon + Intel),
# bundled by hand and ad-hoc signed.
#
# Usage: ./build_app.sh [--run] [--zip]
#   --run   launch after installing to ~/Applications
#   --zip   also write dist/LittleBox.zip to copy to another Mac
set -euo pipefail
cd "$(dirname "$0")"

RUN=0; ZIP=0
for a in "$@"; do
    case "$a" in --run) RUN=1 ;; --zip) ZIP=1 ;; esac
done

# Intel first, so .build/release ends up pointing at the native Apple-silicon build.
echo "▸ Building x86_64…"
nice -n 10 swift build -c release -j 4 --triple x86_64-apple-macosx14.0
echo "▸ Building arm64…"
nice -n 10 swift build -c release -j 4 --triple arm64-apple-macosx14.0

APP_DIR="$HOME/Applications/LittleBox.app"
mkdir -p "$HOME/Applications"
OLD_REQ=$(codesign -d -r- "$APP_DIR" 2>/dev/null | grep designated || true)
pkill -x LittleBox 2>/dev/null || true
sleep 0.3

rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
lipo -create -output "$APP_DIR/Contents/MacOS/LittleBox" \
    .build/arm64-apple-macosx/release/LittleBox \
    .build/x86_64-apple-macosx/release/LittleBox
cp Resources/Info.plist "$APP_DIR/Contents/"
cp Resources/AppIcon.icns "$APP_DIR/Contents/Resources/"

# Ad-hoc signature. macOS ties permissions to it, so a changed build invalidates them;
# then clear LittleBox's own stale entries so the app can simply ask again on launch.
# An identical build keeps its grants.
codesign --force --sign - --identifier com.yijiang.littlebox "$APP_DIR"
NEW_REQ=$(codesign -d -r- "$APP_DIR" 2>/dev/null | grep designated || true)
if [ "$OLD_REQ" != "$NEW_REQ" ]; then
    tccutil reset Accessibility com.yijiang.littlebox >/dev/null 2>&1 || true
    tccutil reset ScreenCapture com.yijiang.littlebox >/dev/null 2>&1 || true
    echo "▸ New signature: permissions reset (grant them again in LittleBox's Settings)"
fi

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_DIR" 2>/dev/null || true
echo "Built: $APP_DIR ($(lipo -archs "$APP_DIR/Contents/MacOS/LittleBox"))"

if [ "$ZIP" = 1 ]; then
    mkdir -p dist
    rm -f dist/LittleBox.zip
    ditto -c -k --keepParent "$APP_DIR" dist/LittleBox.zip
    echo "Zipped: dist/LittleBox.zip"
fi

if [ "$RUN" = 1 ]; then
    open "$APP_DIR"
    echo "Launched."
fi
