import Foundation

/// Represents current AI activity state
struct ActivityState: Identifiable {
    let id = UUID()
    let label: String       // e.g. "AI 思考中", "等待输入"
    let detail: String     // e.g. "最后请求: 14:09:32"
    let color: String       // "green" | "yellow" | "gray"
}

/// Monitors OpenClaw Gateway activity by tailing gateway.log
class BackgroundMonitor: ObservableObject {
    @Published var activity: ActivityState = ActivityState(label: "空闲", detail: "无活跃请求", color: "gray")
    @Published var lastActivity: Date? = nil
    @Published var lastUpdate: Date = Date()

    private var timer: Timer?
    private var lastLogSize: UInt64 = 0
    private let logPath: String

    init() {
        self.logPath = NSHomeDirectory() + "/.openclaw/logs/gateway.log"
        refresh()
    }

    func start() {
        // Initial read
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? UInt64 {
            lastLogSize = size
        }
        refresh()

        // Poll every 3 seconds
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let path = logPath
        guard FileManager.default.fileExists(atPath: path) else {
            DispatchQueue.main.async {
                self.activity = ActivityState(label: "空闲", detail: "Gateway 未运行", color: "gray")
            }
            return
        }

        // Read last ~50 lines of log
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task.arguments = ["-n", "50", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }
        var lastToolCall: String? = nil
        var lastToolTime: String? = nil
        var activeTypes: Set<String> = []

        for line in lines {
            // Detect active tool calls / invokes
            if line.contains("[tool]") || line.contains("tool_call") || line.contains("invoke") {
                if let ts = extractTimestamp(from: line) {
                    lastToolTime = ts
                    if line.contains("exec") || line.contains("command") {
                        lastToolCall = "exec 命令"
                    } else if line.contains("read") || line.contains("file") {
                        lastToolCall = "文件读写"
                    } else if line.contains("browser") || line.contains("page") {
                        lastToolCall = "浏览器"
                    } else if line.contains("message") || line.contains("send") {
                        lastToolCall = "发消息"
                    } else if line.contains("image") || line.contains("generate") {
                        lastToolCall = "生成图片"
                    } else if line.contains("search") || line.contains("fetch") {
                        lastToolCall = "网络请求"
                    } else {
                        lastToolCall = "工具调用"
                    }
                    activeTypes.insert("tool")
                }
            }

            // Detect model API calls (AI thinking)
            if line.contains("[model]") || line.contains("model") || line.contains("completion") || line.contains("chat") {
                if extractTimestamp(from: line) != nil {
                    activeTypes.insert("model")
                }
            }

            // Detect sessions / message activity
            if line.contains("[sessions]") || line.contains("session") || line.contains("feishu") {
                if extractTimestamp(from: line) != nil {
                    activeTypes.insert("message")
                }
            }
        }

        DispatchQueue.main.async {
            self.lastUpdate = Date()

            // Determine state
            if activeTypes.isEmpty {
                self.activity = ActivityState(
                    label: "空闲",
                    detail: "无活跃请求",
                    color: "gray"
                )
            } else if activeTypes.contains("tool") && lastToolCall != nil {
                self.activity = ActivityState(
                    label: "⚡ 执行中",
                    detail: "\(lastToolCall!) · \(lastToolTime ?? "")",
                    color: "green"
                )
            } else if activeTypes.contains("model") {
                self.activity = ActivityState(
                    label: "🤔 AI 思考中",
                    detail: "模型响应中 · \(lastToolTime ?? "")",
                    color: "yellow"
                )
            } else if activeTypes.contains("message") {
                self.activity = ActivityState(
                    label: "📨 消息处理中",
                    detail: lastToolTime ?? "",
                    color: "green"
                )
            } else {
                self.activity = ActivityState(
                    label: "活跃",
                    detail: lastToolTime ?? "",
                    color: "green"
                )
            }
        }
    }

    private func extractTimestamp(from line: String) -> String? {
        // Format: "2026-03-31T14:09:32.123+08:00"
        let pattern = #"(\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}:\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let timeRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return String(line[timeRange])
    }
}
