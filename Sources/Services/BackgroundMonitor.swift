import Foundation

enum AIActivity: String {
    case idle = "空闲"
    case busy = "处理中"
    case stuck = "卡住了"
}

/// Monitors OpenClaw AI activity by watching gateway.log.
/// Key signals from log:
///   dispatching to agent  → new message arrived
///   agent_end             → AI finished processing
///   tool_call             → AI is running a tool (subtype of busy)
///
/// State machine:
///   idle     ← no dispatching seen for a while
///   busy     ← dispatching seen, agent_end not yet
///   stuck    ← dispatching seen, no agent_end for >2min
class BackgroundMonitor: ObservableObject {
    @Published var activity: AIActivity = .idle
    @Published var lastEndedAt: String = "—"     // "HH:mm:ss"
    @Published var lastDispatchAt: String = "—"  // "HH:mm:ss"
    @Published var idleMinutes: Int = 0
    @Published var lastUpdate: Date = Date()

    // Persistent state across refreshes (survives timer gaps)
    private var lastKnownAgentEnd: Date?
    private var awaitingAgentEnd: Bool = false

    private var timer: Timer?
    private let logPath: String

    init() {
        self.logPath = NSHomeDirectory() + "/.openclaw/logs/gateway.log"
        refresh()
    }

    func start() {
        // Use a timer that fires reliably even in background
        // .common mode fires during scrolling/UI updates; add for modal sheets
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        let path = logPath
        guard FileManager.default.fileExists(atPath: path) else {
            setUI(activity: .idle, endedAt: "—", dispatchAt: "—", idleMins: 0)
            return
        }

        // Read last 120 lines — wider window to catch all relevant signals
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task.arguments = ["-n", "120", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Scan chronologically (oldest → newest)
        // Keep only the LATEST instance of each signal
        var latestAgentEndTime: String? = nil
        var latestDispatchTime: String? = nil
        var latestToolCallTime: String? = nil

        for line in lines {
            let ts = extractTimestamp(from: line)

            if ts != nil {
                if line.contains("agent_end") && latestAgentEndTime == nil {
                    latestAgentEndTime = ts
                }
                if line.contains("dispatching to agent") && latestDispatchTime == nil {
                    latestDispatchTime = ts
                }
                if line.contains("tool call:") && latestToolCallTime == nil {
                    latestToolCallTime = ts
                }
            }
        }

        DispatchQueue.main.async {
            self.lastUpdate = Date()

            let now = Date()

            // Update persistent agent_end tracking
            if let endStr = latestAgentEndTime, let endDate = self.parseDate(endStr) {
                self.lastKnownAgentEnd = endDate
                self.awaitingAgentEnd = false
            }

            // State determination
            if latestDispatchTime != nil {
                // New message arrived — must be busy or stuck
                self.awaitingAgentEnd = true

                if let endDate = self.lastKnownAgentEnd {
                    let mins = Int(now.timeIntervalSince(endDate) / 60)
                    if mins >= 2 {
                        self.activity = .stuck
                        self.idleMinutes = mins
                    } else {
                        self.activity = .busy
                        self.idleMinutes = mins
                    }
                } else {
                    // No prior agent_end seen → very recent dispatch, actively starting
                    self.activity = .busy
                    self.idleMinutes = 0
                }
            } else if latestAgentEndTime != nil {
                // No dispatching, but agent has ended recently
                self.activity = .idle
                if let endDate = self.lastKnownAgentEnd {
                    self.idleMinutes = max(0, Int(now.timeIntervalSince(endDate) / 60))
                } else {
                    self.idleMinutes = 0
                }
            } else {
                // No relevant signals in window at all
                if let lastEnd = self.lastKnownAgentEnd {
                    let mins = Int(now.timeIntervalSince(lastEnd) / 60)
                    if mins >= 2 {
                        self.activity = .stuck
                        self.idleMinutes = mins
                    } else {
                        self.activity = .idle
                        self.idleMinutes = mins
                    }
                } else {
                    self.activity = .idle
                    self.idleMinutes = 0
                }
            }

            self.lastEndedAt = latestAgentEndTime ?? self.lastEndedAt
            self.lastDispatchAt = latestDispatchTime ?? self.lastDispatchAt
        }
    }

    private func setUI(activity: AIActivity, endedAt: String, dispatchAt: String, idleMins: Int) {
        DispatchQueue.main.async {
            self.activity = activity
            self.lastEndedAt = endedAt
            self.lastDispatchAt = dispatchAt
            self.idleMinutes = idleMins
            self.lastUpdate = Date()
        }
    }

    private func extractTimestamp(from line: String) -> String? {
        let pattern = #"(\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}:\d{2}))"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let timeRange = Range(match.range(at: 1), in: line) else {
            return nil
        }
        return String(line[timeRange])  // full "YYYY-MM-DDTHH:mm:ss"
    }

    private func parseDate(_ ts: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return fmt.date(from: ts)
    }
}
