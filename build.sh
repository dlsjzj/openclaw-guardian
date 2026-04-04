#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
BIN="$BUILD_DIR/openclaw-guardian"
APP="/Applications/OpenClaw Guardian.app"

mkdir -p "$BUILD_DIR"

echo "📦 Compiling OpenClaw Guardian..."

# Use swift build instead of direct swiftc (handles SQLite.swift dependency)
cd "$PROJECT_DIR"
swift build -c release

# Find the built binary
if [ -f "$BUILD_DIR/openclaw-guardian" ]; then
    BUILT_BIN="$BUILD_DIR/openclaw-guardian"
else
    # Find in release directory
    BUILT_BIN=$(find "$BUILD_DIR" -name "openclaw-guardian" -type f 2>/dev/null | head -1)
fi

if [ -z "$BUILT_BIN" ]; then
    echo "❌ Failed to find built binary"
    exit 1
fi

echo "✅ Built: $BUILT_BIN"

# Install to Applications
mkdir -p "$APP/Contents/MacOS"
cp "$BUILT_BIN" "$APP/Contents/MacOS/"
chmod +x "$APP/Contents/MacOS/openclaw-guardian"
echo "✅ Installed to $APP"

# Auto-commit and push if there are changes
cd "$PROJECT_DIR"
if ! git diff --quiet 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    git add -A
    git commit -m "update: $(date '+%Y-%m-%d %H:%M')" 2>/dev/null
    echo "📦 Committed changes"
    if git push 2>&1 | grep -q "Everything up-to-date"; then
        echo "⬆️  Already up-to-date"
    else
        echo "⬆️  Pushed to GitHub"
    fi
else
    echo "⬆️  No changes to push"
fi

echo ""
echo "⚠️  Quit the running instance first if updating:"
echo "   launchctl unload ~/Library/LaunchAgents/ai.zhongshu.openclaw-guardian.plist"
echo "   launchctl load ~/Library/LaunchAgents/ai.zhongshu.openclaw-guardian.plist"
