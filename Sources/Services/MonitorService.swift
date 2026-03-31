import Foundation

class MonitorService: ObservableObject {
    @Published var status: HealthStatus = .unknown
    @Published var recentEvents: [LogEvent] = []
    @Published var recentFixes: [FixResult] = []
    @Published var isMonitoring: Bool = false
    @Published var gatewayUptime: String = "—"
    
    // MARK: - Rate Limit Status
    @Published var fixAttemptsUsed: Int = 0
    @Published var fixAttemptsMax: Int = 3
    @Published var isRateLimited: Bool = false
    @Published var rateLimitRemainingSeconds: Int? = nil

    private var logWatcher: LogWatcher?
    private var healthTimer: Timer?
    private var uptimeTimer: Timer?
    private var rateLimitTimer: Timer?
    private let healthChecker = HealthChecker()
    private let fixExecutor = FixExecutor()
    private let feishuNotifier = FeishuNotifier()

    var onStatusChange: ((HealthStatus) -> Void)?

    init() {}

    func start() {
        isMonitoring = true
        startLogWatching()
        startHealthCheck()
        startUptimeCheck()
        startRateLimitUpdate()
    }

    func stop() {
        isMonitoring = false
        logWatcher?.stop()
        healthTimer?.invalidate()
        uptimeTimer?.invalidate()
        rateLimitTimer?.invalidate()
    }

    private func startRateLimitUpdate() {
        // Initial update
        updateRateLimitStatus()
        // Update every 5 seconds to keep UI in sync
        rateLimitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.updateRateLimitStatus()
        }
    }

    func forceFixNow() {
        Task {
            let result = await fixExecutor.fixGateway()
            await MainActor.run {
                recentFixes.insert(result, at: 0)
                if recentFixes.count > 20 { recentFixes.removeLast() }
                if result.success {
                    status = .healthy
                    onStatusChange?(.healthy)
                }
                // Update rate limit status
                updateRateLimitStatus()
            }
        }
    }
    
    private func updateRateLimitStatus() {
        let status = fixExecutor.getRateLimitStatus()
        fixAttemptsUsed = status.attemptsUsed
        fixAttemptsMax = status.maxAttempts
        isRateLimited = status.isLimited
        rateLimitRemainingSeconds = status.nextAvailableIn
    }

    func clearHistory() {
        recentEvents.removeAll()
        recentFixes.removeAll()
    }

    // MARK: - Private

    private func startLogWatching() {
        logWatcher = LogWatcher()
        logWatcher?.onNewEvents = { [weak self] events in
            guard let self = self else { return }
            DispatchQueue.main.async {
                for event in events {
                    if !self.isNoiseLine(event) {
                        self.recentEvents.insert(event, at: 0)
                        if self.recentEvents.count > 100 { self.recentEvents.removeLast() }
                        self.evaluateStatusForEvent(event)
                    }
                }
            }
        }
        logWatcher?.start()
    }

    private func startHealthCheck() {
        healthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { [weak self] in
                await self?.checkHealth()
            }
        }
        Task { await checkHealth() }
    }

    private func startUptimeCheck() {
        uptimeTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.updateUptime()
        }
        updateUptime()
    }

    private func checkHealth() async {
        let result = await healthChecker.check()
        await MainActor.run {
            let newStatus: HealthStatus
            switch result {
            case .healthy:
                newStatus = .healthy
            case .unhealthy:
                newStatus = .critical
            case .unknown:
                newStatus = .unknown
            }

            if newStatus != self.status {
                let oldStatus = self.status
                self.status = newStatus
                self.onStatusChange?(newStatus)

                // Send Feishu notification if went critical
                if oldStatus != .critical && newStatus == .critical {
                    self.sendCriticalNotification()
                }
            }
        }
    }

    private func updateUptime() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // Find openclaw-gateway PID from ps output
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/bin/ps")
            task.arguments = ["-ax", "-o", "pid,etime=", "-c"]
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = FileHandle.nullDevice
            try? task.run()
            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else {
                DispatchQueue.main.async { self?.gatewayUptime = "—" }
                return
            }

            // Parse ps output: find openclaw-gateway process
            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                // Format: "pid etime" or "pid command etime" with -c flag
                // With -c flag, output is just "pid etime" space-separated
                if parts.count >= 2 {
                    // Last component is etime, second-to-last is likely pid
                    let etime = parts.last ?? ""
                    let pid = parts.first ?? ""
                    if let pidNum = Int(pid), pidNum > 0 {
                        // Simple heuristic: openclaw gateway usually has short etime on restarts
                        // Just show uptime for gateway processes
                        DispatchQueue.main.async {
                            self?.gatewayUptime = etime
                        }
                        return
                    }
                }
            }

            DispatchQueue.main.async {
                self?.gatewayUptime = "—"
            }
        }
    }

    private func evaluateStatusForEvent(_ event: LogEvent) {
        let msg = event.message.lowercased()
        let criticalPatterns = [
            "oom", "out of memory", "killed",
            "panic", "segfault", "crash",
            "unhandled rejection",
            "fatal error",
            "listen eaddrnotavail",
            "port already in use",
            "eaddrinuse"
        ]

        let warningPatterns = [
            "timeout", "slow query",
            "retry", "reconnecting"
        ]

        if isNoiseLine(event) { return }

        for pattern in criticalPatterns {
            if msg.contains(pattern) {
                status = .critical
                onStatusChange?(.critical)
                Task {
                    let result = await fixExecutor.fixGateway()
                    await MainActor.run {
                        recentFixes.insert(result, at: 0)
                        if recentFixes.count > 20 { recentFixes.removeLast() }
                        updateRateLimitStatus()
                    }
                }
                return
            }
        }

        for pattern in warningPatterns {
            if msg.contains(pattern) && status == .healthy {
                status = .warning
                onStatusChange?(.warning)
                return
            }
        }
    }

    private func sendCriticalNotification() {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        feishuNotifier.notify(
            title: "⚠️ OpenClaw Guardian 检测到故障",
            body: "时间：\(timestamp)\nGateway 状态异常，Guardian 正在尝试自动修复。\n请查看 Guardian Menu Bar 了解详情。"
        )
    }

    private func isNoiseLine(_ event: LogEvent) -> Bool {
        let msg = event.message
        if msg.contains("tool call: exec") ||
           msg.contains("tool done: exec") ||
           msg.contains("dispatching to agent") ||
           msg.contains("\\[36m") ||
           msg.contains("auto-recall") ||
           msg.contains("Telemetry flush") ||
           msg.contains("Loading local embedding") ||
           msg.contains("gateway restart") ||
           msg.contains("session history") ||
           msg.contains("missing tool result") ||
           msg.contains("synthetic error") ||
           msg.contains("auto-recall-skill") ||
           msg.contains("prependContext") {
            return true
        }
        return false
    }
}
