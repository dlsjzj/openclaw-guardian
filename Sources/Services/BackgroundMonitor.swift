import Foundation

enum AIActivity: String {
    case idle = "空闲"
    case busy = "处理中"
    case stuck = "卡住了"
}

/// Detects AI activity from gateway.log using FSEvents (event-driven) + periodic stuck-check.
///
/// Real signals:
///   "[plugins] agent_end"  → AI finished processing (NOT inside tool call params)
///   "dispatching to agent" → new message arrived
///   "tool call:"           → feishu tool invocation (NOT inside another tool's params)
///
/// State:
///   busy   ← dispatch + tool call started (even if prior agent_end exists)
///   idle   ← dispatch ended cleanly, no new dispatch
///   stuck  ← dispatch >2min with no work started
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

    // MARK: - FSEvents (replaces fixed 3-second polling)
    private var fileMonitorSource: DispatchSourceFileSystemObject?
    private var monitoredFileHandle: FileHandle?
    private var monitoredFileDescriptor: Int32 = -1

    // MARK: - Periodic stuck-check timer (still needed since FSEvents only fires on file changes)
    private var stuckTimer: Timer?

    private let logPath: String

    init() {
        self.logPath = NSHomeDirectory() + "/.openclaw/logs/gateway.log"
        refresh()
    }

    func start() {
        stop()

        // FSEvents: watch log file for changes, trigger re-scan on write activity
        setupFileMonitor()

        // Periodic stuck-check: catches cases where log hasn't changed but AI is stuck
        // Run every 30 seconds — much cheaper than 3-second polling
        stuckTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.checkStuck()
        }
        RunLoop.main.add(stuckTimer!, forMode: .common)
    }

    func stop() {
        stuckTimer?.invalidate()
        stuckTimer = nil

        fileMonitorSource?.cancel()
        fileMonitorSource = nil

        try? monitoredFileHandle?.close()
        monitoredFileHandle = nil
        monitoredFileDescriptor = -1
    }

    // MARK: - FSEvents file monitoring

    /// Sets up DispatchSource.makeFileSystemObject to watch the log file.
    /// Triggers a debounced re-scan whenever the file is written to.
    private func setupFileMonitor() {
        guard FileManager.default.fileExists(atPath: logPath) else { return }

        // Open file for reading (watching writable events requires write descriptor, simpler to
        // watch the file's modification time via a read handle and re-check on any activity)
        do {
            let url = URL(fileURLWithPath: logPath)
            monitoredFileHandle = try FileHandle(forReadingFrom: url)
            monitoredFileDescriptor = monitoredFileHandle!.fileDescriptor
        } catch {
            print("[BackgroundMonitor] Could not open log file for monitoring: \(error)")
            return
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: monitoredFileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: DispatchQueue.global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            // File was modified — trigger debounced scan
            self?.throttledRefresh()
        }

        source.setCancelHandler { [weak self] in
            try? self?.monitoredFileHandle?.close()
            self?.monitoredFileHandle = nil
            self?.monitoredFileDescriptor = -1
        }

        fileMonitorSource = source
        source.resume()
    }

    /// Checks if AI is stuck even without log changes (periodic 30s check)
    private func checkStuck() {
        let now = Date()

        guard let dispatchDate = lastKnownDispatch else {
            // No dispatch at all → idle
            DispatchQueue.main.async {
                if self.activity != .idle {
                    self.activity = .idle
                    self.idleMinutes = 0
                    self.lastUpdate = now
                }
            }
            return
        }

        let dispatchAgeSecs = Int(now.timeIntervalSince(dispatchDate))
        guard dispatchAgeSecs >= 120 else { return }  // Not stuck yet

        guard let toolCallDate = lastKnownAgentEnd else {
            // No agent_end after dispatch → stuck
            setUI(activity: .stuck, endedAt: lastEndedAt, toolAt: lastToolCallAt, dispatchAt: lastDispatchAt, idleMins: dispatchAgeSecs / 60)
            return
        }

        // If last agent_end is older than 2min from dispatch and no new work → stuck
        if toolCallDate < dispatchDate.addingTimeInterval(120) {
            setUI(activity: .stuck, endedAt: lastEndedAt, toolAt: lastToolCallAt, dispatchAt: lastDispatchAt, idleMins: dispatchAgeSecs / 60)
        }
    }

    /// Skip refresh if called within 1.5s of last call (debounce rapid log writes)
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

        // Use grep to pre-filter lines.
        // BUG FIX: Use [plugins] prefix for agent_end to avoid matching "agent_end"
        // appearing inside tool call command parameters (e.g., grep -E "agent_end").
        // Also scan 500 lines instead of 120 to capture agent_end even with many tool calls.
        let shellCmd = "tail -n 500 \"\(path)\" | grep -E '\\[plugins\\] agent_end|dispatching to agent|tool call:'"
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
        // BUG FIX: Changed order — scan for tool call FIRST (most reliable indicator
        // of active work), then dispatch, then agent_end. This avoids a subtle bug
        // where old agent_end from previous session was incorrectly clearing busy
        // state when a new tool call arrived.
        var latestAgentEndTime: String? = nil
        var latestDispatchTime: String? = nil
        var latestToolCallTime: String? = nil

        for line in lines.reversed() {
            let ts = extractTimestamp(from: line)
            if ts == nil { continue }

            // Scan tool call FIRST — most reliable signal of active work
            if latestToolCallTime == nil && line.contains("tool call:") {
                latestToolCallTime = ts
            } else if latestDispatchTime == nil && line.contains("dispatching to agent") {
                latestDispatchTime = ts
            } else if latestAgentEndTime == nil && line.contains("[plugins] agent_end") {
                // BUG FIX: Only match "[plugins] agent_end" to avoid false matches
                // where "agent_end" appears inside command strings like:
                // "command":"grep -E \"agent_end|...\""
                latestAgentEndTime = ts
            }

            if latestToolCallTime != nil && latestDispatchTime != nil && latestAgentEndTime != nil {
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

        // Determine state — simplified, robust logic
        //
        // Key principle: if there's a dispatch and recent tool call activity
        // (tool call AFTER dispatch), AI is busy. The tool call is the ground
        // truth for "AI is doing something NOW".
        //
        // We NEVER use agent_end to clear a busy state when a new tool call
        // has since arrived — tool call newer than agent_end means NEW work started.
        //
        let toolCallDate: Date? = latestToolCallTime.flatMap { parseDate($0) }
        let agentEndDate: Date? = latestAgentEndTime.flatMap { parseDate($0) }
        let dispatchDate: Date? = latestDispatchTime.flatMap { parseDate($0) }

        var newActivity: AIActivity = .idle
        var newIdleSecs: Int = 0

        if let dispDate = dispatchDate {
            // A dispatch exists — this is a live (or recent) session
            let dispatchAgeSecs = Int(now.timeIntervalSince(dispDate))

            // Primary check: if there's a tool call AFTER dispatch, AI is busy
            // (tool call is the strongest signal of active work)
            if let toolDate = toolCallDate, toolDate >= dispDate {
                let toolAgeSecs = Int(now.timeIntervalSince(toolDate))
                newActivity = .busy
                newIdleSecs = toolAgeSecs
            }
            // No tool call after this dispatch
            else {
                // Check if there's an agent_end for THIS dispatch (end after dispatch)
                if let endDate = agentEndDate, endDate >= dispDate {
                    let endAgeSecs = Int(now.timeIntervalSince(endDate))
                    if endAgeSecs >= 120 {
                        newActivity = .stuck
                    } else {
                        newActivity = .idle
                    }
                    newIdleSecs = endAgeSecs
                }
                // No tool call, no agent_end for this dispatch
                else {
                    if dispatchAgeSecs >= 120 {
                        newActivity = .stuck
                    } else {
                        // Dispatch arrived but work hasn't started yet → waiting
                        newActivity = .busy
                    }
                    newIdleSecs = dispatchAgeSecs
                }
            }
        } else {
            // No dispatch at all → check idle time since last agent_end
            if let endDate = agentEndDate {
                let endAgeSecs = Int(now.timeIntervalSince(endDate))
                newActivity = endAgeSecs >= 120 ? .stuck : .idle
                newIdleSecs = endAgeSecs
            } else {
                newActivity = .idle
                newIdleSecs = 0
            }
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
