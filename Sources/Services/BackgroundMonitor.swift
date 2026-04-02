import Foundation

enum AIActivity: String {
    case idle = "空闲"
    case busy = "处理中"
    case stuck = "卡住了"
}

/// Detects AI activity from gateway.log.
///
/// Real signals (must have specific prefix to avoid false matches):
///   "tool call:"  → actual feishu tool invocation
///   "agent_end"           → AI finished processing
///   "dispatching to agent" → new message arrived
///
/// State:
///   busy   ← feishu tool call seen in last 120 lines (AI doing work NOW)
///   idle   ← no feishu tool call; last agent_end < 2 min ago
///   stuck  ← no feishu tool call AND > 2 min since any meaningful activity
///
class BackgroundMonitor: ObservableObject {
    @Published var activity: AIActivity = .idle
    @Published var lastEndedAt: String = "—"
    @Published var lastToolCallAt: String = "—"
    @Published var lastDispatchAt: String = "—"
    @Published var idleMinutes: Int = 0
    @Published var lastUpdate: Date = Date()

    private var lastRefresh: Date = Date.distantPast
    private var lastRefreshToken: Int = 0  // incremented each refresh
    private var refreshSeq: Int = 0       // monotonic refresh counter

    private var lastKnownAgentEnd: Date?
    private var lastKnownDispatch: Date?
    private var dispatchArrivedAfterEnd: Bool = false

    private var timer: Timer?
    private let logPath: String

    init() {
        self.logPath = NSHomeDirectory() + "/.openclaw/logs/gateway.log"
        refresh()
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.throttledRefresh()
        }
        RunLoop.main.add(timer!, forMode: .common)
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Skip refresh if called within 1.5s of last call (debounce tab switching etc.)
    private func throttledRefresh() {
        let now = Date()
        guard now.timeIntervalSince(lastRefresh) >= 1.5 else { return }
        lastRefresh = now
        refreshSeq += 1
        refresh(token: refreshSeq)
    }

    func refresh() {
        throttledRefresh()
    }

    private func refresh(token: Int) {
        guard token == refreshSeq else { return }  // discard stale calls

        let path = logPath
        guard FileManager.default.fileExists(atPath: path) else {
            setUI(activity: .idle, endedAt: "—", toolAt: "—", dispatchAt: "—", idleMins: 0)
            return
        }

        // Use grep to pre-filter lines so we don't read entire log into Swift
        let shellCmd = "tail -n 120 \"\(path)\" | grep -E 'tool call:|agent_end|dispatching to agent'"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/sh")
        task.arguments = ["-c", shellCmd]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }

        // Scan newest-first; take first occurrence of each signal
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

            if latestAgentEndTime != nil && latestDispatchTime != nil && latestToolCallTime != nil {
                break
            }
        }

        let now = Date()

        // Update persistent timestamps
        if let endStr = latestAgentEndTime, let d = parseDate(endStr) {
            lastKnownAgentEnd = d
        }
        if let dispStr = latestDispatchTime, let d = parseDate(dispStr) {
            lastKnownDispatch = d
            dispatchArrivedAfterEnd = true
        }

        // Determine state — simpler, more robust
        // Key principle: show "busy" if any recent tool activity, otherwise idle/stuck
        var newActivity: AIActivity = .idle
        var newIdleSecs: Int = 0

        let toolCallDate: Date? = latestToolCallTime.flatMap { parseDate($0) }
        let agentEndDate: Date? = latestAgentEndTime.flatMap { parseDate($0) }

        if let toolDate = toolCallDate {
            let toolAgeSecs = Int(now.timeIntervalSince(toolDate))
            if toolAgeSecs < 60 {
                // Recent tool activity (< 60s) → busy
                newActivity = .busy
                newIdleSecs = toolAgeSecs
            } else {
                // Tool call was > 60s ago
                if let endDate = agentEndDate {
                    let endAgeSecs = Int(now.timeIntervalSince(endDate))
                    if endAgeSecs < 120 {
                        // agent_end within 2 min → idle
                        newActivity = .idle
                        newIdleSecs = endAgeSecs
                    } else {
                        // > 2 min since any activity → stuck
                        newActivity = .stuck
                        newIdleSecs = endAgeSecs
                    }
                } else {
                    // No agent_end, tool was > 60s ago
                    newActivity = .stuck
                    newIdleSecs = toolAgeSecs
                }
            }
        } else if let endDate = agentEndDate {
            // No tool call, but have agent_end
            let endAgeSecs = Int(now.timeIntervalSince(endDate))
            newActivity = endAgeSecs >= 120 ? .stuck : .idle
            newIdleSecs = endAgeSecs
        } else if let dispatch = lastKnownDispatch {
            // No tool call, no agent_end, but dispatch seen
            let dispatchAgeSecs = Int(now.timeIntervalSince(dispatch))
            // If dispatch is very recent (< 60s), likely work just started
            if dispatchAgeSecs < 60 {
                newActivity = .busy
                newIdleSecs = dispatchAgeSecs
            } else {
                newActivity = dispatchAgeSecs >= 120 ? .stuck : .busy
                newIdleSecs = dispatchAgeSecs
            }
        } else {
            newActivity = .idle
            newIdleSecs = 0
        }

        setUI(
            activity: newActivity,
            endedAt: latestAgentEndTime ?? "—",
            toolAt: latestToolCallTime ?? "—",
            dispatchAt: latestDispatchTime ?? "—",
            idleMins: newIdleSecs / 60
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
