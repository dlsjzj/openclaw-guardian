# OpenClaw Guardian

> macOS Menu Bar 应用，监控 OpenClaw Gateway 健康状态，自动修复故障，宕机时主动飞书通知。

**独立于 OpenClaw Agent 运行** — 即使 Agent 崩溃，Guardian 依然可以检测、重启、发通知。

---

## 功能特性

- 🟢 **实时监控** — 每 30 秒检查 Gateway `/health` API
- 🔍 **日志分析** — 实时读取 `~/.openclaw/logs/gateway.log`，识别 OOM / 崩溃 / 端口冲突
- 🔧 **自动修复** — 检测到故障自动重启 Gateway（最多 3 次）
- 📲 **飞书通知** — 故障时主动发飞书消息（凭证从 OpenClaw 配置读取）
- ⚡ **AI 活动监控** — 后台 Tab 实时显示 AI 是空闲 / 处理中 / 卡住了
- 📊 **自检报告** — 一键检查 Docker / 记忆文件 / Skills / Cron / 备份状态
- 🔄 **开机自启** — LaunchAgent 配置

---

## 构建

### 环境要求
- macOS 12+（Apple Silicon）
- Swift 5.9+
- **不需要 Xcode**（直接用 swiftc）

### 编译
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
  Sources/Services/BackgroundMonitor.swift \
  Sources/Sources/Views/StatusBarView.swift \
  Sources/App/AppDelegate.swift \
  Sources/App/main.swift
```

---

## 安装

```bash
# 部署
cp .build/openclaw-guardian "/Applications/OpenClaw Guardian.app/Contents/MacOS/"
chmod +x "/Applications/OpenClaw Guardian.app/Contents/MacOS/openclaw-guardian"

# 开机自启
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

---

## 架构

```
Sources/
├── App/
│   ├── main.swift              # 入口：手动 NSApplication.shared + NSApp.setActivationPolicy
│   └── AppDelegate.swift        # NSStatusItem + NSPopover 管理，绑定 Tab 视图
├── Models/
│   └── HealthStatus.swift      # HealthLevel 枚举 + FixEvent 记录结构
├── Services/
│   ├── HealthChecker.swift       # GET http://127.0.0.1:18789/health → ok=true?
│   ├── LogWatcher.swift         # 尾读 gateway.log，检测 OOM/crash/port conflict
│   ├── FixExecutor.swift         # 执行 openclaw gateway restart，限流 3 次/轮
│   ├── MonitorService.swift      # 定时调度器（30s 检查）+ 事件聚合 + 飞书通知触发
│   ├── SelfChecker.swift        # Docker/记忆文件/Skills/Cron/备份 5 项检查
│   ├── FeishuNotifier.swift     # 读取 openclaw.json → 获取 appId/appSecret → 发飞书
│   └── BackgroundMonitor.swift  # 尾读日志 → 检测 AI 空闲/处理中/卡住
└── Views/
    └── StatusBarView.swift     # SwiftUI PopoverContent，5 个 Tab（事件/修复/自检/操作/后台）
```

---

## 核心实现细节

### 健康检查逻辑（HealthChecker）

每 30 秒调用 `http://127.0.0.1:18789/health`：
- 返回 `{"ok":true,"status":"live"}` → 正常
- 超时 / 错误 → 三次确认（避免误报）

> ⚠️ 不要用 `/v1/models` 检测——它返回的是 Control Center HTML，不是 JSON。

### 自动修复逻辑（FixExecutor）

检测到故障后执行：
```bash
openclaw gateway restart
```
限流：每轮最多重启 3 次，间隔 >30s 才会再次重启。防止 Gateway 反复重启。

### 飞书通知（FeishuNotifier）

凭证从 OpenClaw 配置读取，不硬编码：
```bash
~/.openclaw/openclaw.json → channels.feishu.appId / appSecret
```
通知触发：状态从正常变为 critical 时发送，不重复通知。

### AI 活动监控（BackgroundMonitor）

读取 `~/.openclaw/logs/gateway.log` 最近 120 行，用 grep 预过滤：

```
grep "feishu: tool call:|agent_end|dispatching to agent"
```

**状态判断（重要）：**
- ⚡ **处理中** ← 日志中有 `feishu: tool call:`（实际工具调用）
- 🌙 **空闲** ← 无 tool call，agent_end 距今 < 2 分钟
- ⚠️ **卡住了** ← 无 tool call，且 > 2 分钟没有任何活动

> ⚠️ 匹配规则必须是 `feishu: tool call:` 而不是 `tool call:`，否则会误匹配代码中的字符串。

**防抖：** 1.5 秒内重复刷新跳过，避免 Tab 切换时卡顿。

**⚠️ Swift String Interpolation 注意：**
```swift
// ❌ 错误：Swift raw string (#"..."#) 不支持 \(var) 插值
task.arguments = ["-c", #"tail -n 120 '#(path)' | grep ..."#]

// ✅ 正确：使用普通字符串插值
let cmd = "tail -n 120 \"\(path)\" | grep ..."
task.arguments = ["-c", cmd]
```

### 日志监听（LogWatcher）

监听 `~/.openclaw/logs/gateway.log` 尾段，检测关键词：
- `OOM Killer` / `killed` → 内存不足
- `port.*already in use` / `Address already in use` → 端口冲突
- `Gateway startup timed out` → 启动超时
- `Process.*exited` → 进程退出

---

## 配置

### 飞书凭证（可选）

确保 `~/.openclaw/openclaw.json` 包含：
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

### Gateway 路径

默认：`/opt/homebrew/bin/openclaw`（Homebrew 安装路径）

如需修改，编辑 `FixExecutor.swift` 中的 `openclawBin` 常量。

---

## 如何扩展

### 增加新的检测关键词

编辑 `LogWatcher.swift` → `scanLogFile()` → 添加新的关键词分支。

### 增加新的自检项

编辑 `SelfChecker.swift` → `runChecks()` → 添加新的检查项。

### 调整检查频率

编辑 `MonitorService.swift` → `healthCheckInterval`（默认 30 秒）。

---

## 与 OpenClaw 的关系

| | Guardian | OpenClaw Agent |
|---|---|---|
| 进程 | 独立 Menu Bar App | AI 对话引擎 |
| 依赖 | 只依赖 Gateway 进程 | 依赖 Gateway + 模型 API |
| 崩溃时 | Guardian 仍可运行并通知 | Agent 完全无响应 |
| 修复能力 | 可重启 Gateway | 无法自我修复 |

---

## License

MIT
