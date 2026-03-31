import Foundation

/// What the AI is doing right now
enum AIActivity: String {
    case idle = "空闲"
    case busy = "处理中"
    case stuck = "卡住了"
}

/// Monitors OpenClaw AI activity by tailing gateway.log
/// Key signals:
///   - agent_end      → AI finished processing a request
///   - dispatching    → new message arrived and is being processed
///   - stuck = dispatching seen but no agent_end for >2min
class BackgroundMonitor: ObservableObject {
    @Published var activity: AIActivity = .idle
    @Published var lastEndedAt: String = "—"      // HH:mm:ss of last agent_end
    @Published var lastDispatchAt: String = "—"   // HH:mm:ss of last dispatching
    @Published var idleMinutes: Int = 0           // minutes since last agent_end
    @Published var lastUpdate: Date = Date()

    private var timer: Timer?
    private let logPath: String

    // Track the last agent_end timestamp we've seen
    private var lastAgentEndDate: Date?

    // Track if we're currently in a "waiting for agent_end" state
    private var awaitingAgentEnd: Bool = false

    init() {
        self.logPath = NSHomeDirectory() + "/.openclaw/logs/gateway.log"
        refresh()
    }

    func start() {
        refresh()
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
                self.activity = .idle
                self.lastEndedAt = "—"
                self.lastDispatchAt = "—"
                self.idleMinutes = 0
                self.awaitingAgentEnd = false
            }
            return
        }

        // Read last 60 lines — enough to capture recent activity
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/tail")
        task.arguments = ["-n", "60", path]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return }

        let lines = output.components(separatedBy: "\n").filter { !$0.isEmpty }.reversed()  // newest first

        var newestAgentEnd: String? = nil
        var newestDispatch: String? = nil
        var hasAgentEnd: Bool = false
        var hasDispatching: Bool = false

        for line in lines {
            let ts = extractTimestamp(from: line)
            if ts == nil { continue }

            // Check for agent_end (AI finished processing)
            if line.contains("agent_end") && !hasAgentEnd {
                hasAgentEnd = true
                newestAgentEnd = ts
            }

            // Check for dispatching to agent (new message arrived)
            if line.contains("dispatching to agent") && !hasDispatching {
                hasDispatching = true
                newestDispatch = ts
            }
        }

        DispatchQueue.main.async {
            self.lastUpdate = Date()

            // Update timestamps
            if let end = newestAgentEnd {
                self.lastEndedAt = end
            }
            if let disp = newestDispatch {
                self.lastDispatchAt = disp
            }

            // Determine state
            if hasAgentEnd && hasDispatching {
                // Both seen → currently processing
                self.activity = .busy
                self.awaitingAgentEnd = true
                if let end = newestAgentEnd, let date = self.parseTime(end) {
                    self.lastAgentEndDate = date
                    self.idleMinutes = 0
                }
            } else if hasAgentEnd && !hasDispatching {
                // agent_end present, no new dispatching → idle
                self.activity = .idle
                self.awaitingAgentEnd = false
                if let end = newestAgentEnd, let date = self.parseTime(end) {
                    self.lastAgentEndDate = date
                    self.idleMinutes = Int(Date().timeIntervalSince(date) / 60)
                }
            } else if hasDispatching && !hasAgentEnd {
                // dispatching but no agent_end → might be stuck
                // Check: is last agent_end recent enough?
                if let lastEnd = self.lastAgentEndDate {
                    let mins = Int(Date().timeIntervalSince(lastEnd) / 60)
                    if mins >= 2 {
                        // More than 2 minutes since last agent_end → stuck
                        self.activity = .stuck
                        self.idleMinutes = mins
                    } else {
                        self.activity = .busy
                        self.idleMinutes = mins
                    }
                } else {
                    // Never saw agent_end yet → actively processing
                    self.activity = .busy
                    self.idleMinutes = 0
                }
                self.awaitingAgentEnd = true
            } else {
                // No signal at all → check how long since last known agent_end
                if let lastEnd = self.lastAgentEndDate {
                    let mins = Int(Date().timeIntervalSince(lastEnd) / 60)
                    if mins >= 2 {
                        self.activity = .stuck
                    } else {
                        self.activity = .idle
                    }
                    self.idleMinutes = mins
                } else {
                    self.activity = .idle
                    self.idleMinutes = 0
                }
            }
        }
    }

    private func extractTimestamp(from line: String) -> String? {
        let pattern = #"(\d{4}-\d{2}-\d{2}T(\d{2}:\d{2}:\d{2})"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
              let timeRange = Range(match.range(at: 2), in: line) else {
            return nil
        }
        return String(line[timeRange])
    }

    private func parseTime(_ timeStr: String) -> Date? {
        let fmt = DateFormatter()
        fmt.dateFormat = "HH:mm:ss"
        let today = fmt.string(from: Date())
        let full = today.prefix(11) + timeStr  // "YYYY-MM-DDTHH:mm:ss"
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return fmt.date(from: String(full))
    }
}
