import Foundation

enum AIActivity: String {
    case idle = "空闲"
    case busy = "处理中"
    case stuck = "卡住了"
}

/// Monitors OpenClaw AI activity by watching gateway.log.
///
/// Key log signals (chronologically within one turn):
///   dispatching to agent  → new message arrived at AI
///   tool call: <name>    → AI is actively doing work  ← most reliable busy signal
///   agent_end            → AI finished the turn
///
/// Detection logic:
///   busy     ← tool call found in last 120 lines
///   idle     ← no tool call found, but agent_end is recent (< 2 min ago)
///   stuck    ← no tool call AND no agent_end seen for > 2 min after dispatching
///
class BackgroundMonitor: ObservableObject {
    @Published var activity: AIActivity = .idle
    @Published var lastEndedAt: String = "—"
    @Published var lastToolCallAt: String = "—"
    @Published var lastDispatchAt: String = "—"
    @Published var idleMinutes: Int = 0
    @Published var lastUpdate: Date = Date()

    // Persistent across refresh calls
    private var lastKnownAgentEnd: Date?
    private var lastKnownDispatch: Date?
    private var dispatchInProgress: Bool = false

    private var timer: Timer?
    private let logPath: String

    init() {
        self.logPath = NSHomeDirectory() + "/.openclaw/logs/gateway.log"
        refresh()
    }

    func start() {
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
            setUI(activity: .idle, endedAt: "—", toolAt: "—", dispatchAt: "—", idleMins: 0)
            return
        }

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

        // Track newest signals (scan newest-first, take first occurrence of each)
        var latestAgentEndTime: String? = nil
        var latestDispatchTime: String? = nil
        var latestToolCallTime: String? = nil

        for line in lines.reversed() {
            let ts = extractTimestamp(from: line)
            if ts == nil { continue }

            if latestAgentEndTime == nil && line.contains("agent_end") {
                latestAgentEndTime = ts
            } else if latestDispatchTime == nil && line.contains("dispatching to agent") {
                latestDispatchTime = ts
            } else if latestToolCallTime == nil && line.contains("tool call:") {
                latestToolCallTime = ts
            }

            // Stop once we have all three
            if latestAgentEndTime != nil && latestDispatchTime != nil && latestToolCallTime != nil {
                break
            }
        }

        let now = Date()

        // Update persistent state
        if let endStr = latestAgentEndTime, let d = parseDate(endStr) {
            lastKnownAgentEnd = d
        }
        if let dispStr = latestDispatchTime, let d = parseDate(dispStr) {
            lastKnownDispatch = d
            dispatchInProgress = true
        }

        // Determine activity
        var newActivity: AIActivity = .idle
        var newIdleMins: Int = 0

        if latestToolCallTime != nil {
            // Tool call seen in window → AI is actively working
            newActivity = .busy
        } else if let dispatch = lastKnownDispatch, let end = lastKnownAgentEnd {
            // No tool call — check if we are stuck
            if dispatch > end {
                // Dispatch is newer than last agent_end: dispatch arrived, no tool yet
                let mins = Int(now.timeIntervalSince(dispatch) / 60)
                if mins >= 2 {
                    newActivity = .stuck
                    newIdleMins = mins
                } else {
                    // Dispatch is very recent (< 2 min), no tool yet → still busy
                    newActivity = .busy
                }
            } else {
                // agent_end is newer than dispatch: previous cycle ended
                newIdleMins = max(0, Int(now.timeIntervalSince(end) / 60))
                if newIdleMins >= 2 {
                    newActivity = .stuck
                } else {
                    newActivity = .idle
                }
                dispatchInProgress = false
            }
        } else if let end = lastKnownAgentEnd {
            // Only agent_end known, no dispatching
            newIdleMins = max(0, Int(now.timeIntervalSince(end) / 60))
            newActivity = newIdleMins >= 2 ? .stuck : .idle
        } else if let dispatch = lastKnownDispatch {
            // Only dispatch known, no agent_end ever
            let mins = Int(now.timeIntervalSince(dispatch) / 60)
            newIdleMins = mins
            newActivity = mins >= 2 ? .stuck : .busy
        } else {
            // Nothing known
            newActivity = .idle
            newIdleMins = 0
        }

        setUI(
            activity: newActivity,
            endedAt: latestAgentEndTime ?? "—",
            toolAt: latestToolCallTime ?? "—",
            dispatchAt: latestDispatchTime ?? lastDispatchAt,
            idleMins: newIdleMins
        )
    }

    private func setUI(activity: AIActivity, endedAt: String, toolAt: String, dispatchAt: String, idleMins: Int) {
        DispatchQueue.main.async {
            self.activity = activity
            self.lastEndedAt = endedAt
            self.lastToolCallAt = toolAt
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
        return String(line[timeRange])
    }

    private func parseDate(_ ts: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        fmt.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return fmt.date(from: ts)
    }
}
