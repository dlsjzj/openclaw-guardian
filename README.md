# OpenClaw Guardian

> OpenClaw 的守护者 — macOS Menu Bar 应用，监控 Gateway 健康状态，自动修复故障，宕机时主动飞书通知。

## 功能特性

- 🟢 **实时监控** — 每 30 秒检查 Gateway 健康状态
- 🔍 **日志分析** — 实时读取 `~/.openclaw/logs/gateway.log`，识别 OOM/崩溃/超时
- 🔧 **自动修复** — 检测到故障自动重启 Gateway
- 📲 **飞书通知** — 故障时主动发飞书消息，告知用户
- 📊 **自检报告** — 一键检查 Docker / 记忆文件 / Skills / Cron / 备份状态
- ⚙️ **开机自启** — LaunchAgent 配置，开机自动运行

## 界面预览

Menu Bar 三色图标：
- 🟢 绿色 — Gateway 正常运行
- 🟡 黄色 — 检测到警告（timeout/retry）
- 🔴 红色 — 需要修复（OOM/崩溃/端口冲突）

四个 Tab：
- **事件** — 实时日志事件
- **修复** — 修复历史记录
- **自检** — 系统健康报告
- **操作** — 手动修复 / 清除历史

## 构建要求

- macOS 12+
- Xcode **不需要**（直接用 swiftc 编译）
- Swift 5.9+

## 快速构建

```bash
cd ~/.openclaw/workspace-zhongshu/projects/openclaw-guardian

SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk"
swiftc -o .build/openclaw-guardian \
  -sdk "$SDK" \
  -target arm64-apple-macosx26.0 \
  -Xlinker -syslibroot -Xlinker "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework Foundation \
  Sources/Models/HealthStatus.swift \
  Sources/Services/LogWatcher.swift \
  Sources/Services/HealthChecker.swift \
  Sources/Services/FixExecutor.swift \
  Sources/Services/MonitorService.swift \
  Sources/Services/SelfChecker.swift \
  Sources/Services/FeishuNotifier.swift \
  Sources/Views/StatusBarView.swift \
  Sources/App/AppDelegate.swift \
  Sources/App/main.swift
```

## 安装

```bash
# 复制到 Applications
cp .build/openclaw-guardian /Applications/OpenClaw\ Guardian.app/Contents/MacOS/
chmod +x /Applications/OpenClaw\ Guardian.app/Contents/MacOS/openclaw-guardian

# 配置开机自启（需要替换 YOUR_USERNAME）
cat > ~/Library/LaunchAgents/ai.zhongshu.openclaw-guardian.plist << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "...">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.zhongshu.openclaw-guardian</string>
  <key>ProgramArguments</key>
  <array>
    <string>/Applications/OpenClaw Guardian.app/Contents/MacOS/openclaw-guardian</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
</dict>
</plist>
EOF

launchctl load ~/Library/LaunchAgents/ai.zhongshu.openclaw-guardian.plist
```

## 配置说明

### 飞书通知（可选）

Guardian 自动从 OpenClaw 配置读取飞书凭证（`~/.openclaw/openclaw.json` 中的 `channels.feishu.appId` 和 `appSecret`）。

确保这些字段存在于配置中：
```json
{
  "channels": {
    "feishu": {
      "appId": "cli_xxx",
      "appSecret": "xxx"
    }
  }
}
```

用户 open_id 默认使用 `ou_975dc23daa3e73992e35ec29af92a1cb`（可在 `FeishuNotifier.swift` 中修改）。

### Gateway 路径

默认使用 `/opt/homebrew/bin/openclaw`（Homebrew 安装路径）。如需修改，编辑 `FixExecutor.swift` 中的 `openclawBin` 常量。

## 架构

```
Sources/
├── App/
│   ├── main.swift              # 入口点（手动 NSApplicationShared）
│   └── AppDelegate.swift        # Menu Bar + Popover 管理
├── Models/
│   └── HealthStatus.swift      # 健康状态枚举
├── Services/
│   ├── HealthChecker.swift      # /health API 检查
│   ├── LogWatcher.swift          # 实时日志监听
│   ├── FixExecutor.swift         # 自动修复（重启 Gateway）
│   ├── MonitorService.swift      # 监控核心（定时 + 事件）
│   ├── SelfChecker.swift         # 自检报告（Docker/文件/Skills）
│   └── FeishuNotifier.swift     # 飞书通知
└── Views/
    └── StatusBarView.swift     # SwiftUI Menu Bar 面板
```

## 与 OpenClaw 的关系

Guardian **独立运行**于 OpenClaw Agent 之外。即使 Agent 完全崩溃，Guardian 依然可以：
1. 检测到 Gateway 无响应
2. 自动重启 Gateway
3. 发送飞书通知告知用户

Guardian 不依赖 Agent 的任何工具或 API。

## License

MIT
