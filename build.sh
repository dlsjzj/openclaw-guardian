#!/bin/bash
set -e

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$PROJECT_DIR/.build"
BIN="$BUILD_DIR/openclaw-guardian"
APP="/Applications/OpenClaw Guardian.app"

mkdir -p "$BUILD_DIR"

echo "📦 Compiling OpenClaw Guardian..."

swiftc -o "$BIN" \
  -sdk "$SDK" \
  -target arm64-apple-macosx26.0 \
  -Xlinker -syslibroot -Xlinker "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Foundation \
  "$PROJECT_DIR/Sources/Models/HealthStatus.swift" \
  "$PROJECT_DIR/Sources/Models/ErrorClassifier.swift" \
  "$PROJECT_DIR/Sources/Services/LogWatcher.swift" \
  "$PROJECT_DIR/Sources/Services/HealthChecker.swift" \
  "$PROJECT_DIR/Sources/Services/FixExecutor.swift" \
  "$PROJECT_DIR/Sources/Services/MonitorService.swift" \
  "$PROJECT_DIR/Sources/Services/SelfChecker.swift" \
  "$PROJECT_DIR/Sources/Services/FeishuNotifier.swift" \
  "$PROJECT_DIR/Sources/Services/BackgroundMonitor.swift" \
  "$PROJECT_DIR/Sources/Views/StatusBarView.swift" \
  "$PROJECT_DIR/Sources/App/AppDelegate.swift" \
  "$PROJECT_DIR/Sources/App/main.swift"

echo "✅ Built: $BIN"

# Install to Applications
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/"
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
