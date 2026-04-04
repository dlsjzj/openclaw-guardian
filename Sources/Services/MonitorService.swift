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

    // MARK: - API Error Stats
    @Published var apiErrorStats: APIErrorStats = APIErrorStats()
    @Published var lastAPIErrorTime: String = "—"
    @Published var lastAPIErrorCategory: ErrorCategory = .normal

    private var logWatcher: LogWatcher?
    private var healthTimer: Timer?
    private var uptimeTimer: Timer?
    private var rateLimitTimer: Timer?
    private let healthChecker = HealthChecker()
    private let fixExecutor = FixExecutor()
    private let feishuNotifier = FeishuNotifier()
    private let diagnosisEngine = DiagnosisEngine()
    private let fixRouter = FixRouter()
    private let db = DatabaseService.shared

    var onStatusChange: ((HealthStatus) -> Void)?

    init() {}

    func start() {
        isMonitoring = true
        // Clean up old DB records (7-day retention)
        db.cleanupOldData(days: 7)
        db.recordSystemEvent(eventType: "guardian_started", message: "Guardian started")
        startLogWatching()
        startHealthCheck()
        startUptimeCheck()
        startRateLimitUpdate()
    }

    func stop() {
        isMonitoring = false
        db.recordSystemEvent(eventType: "guardian_stopped", message: "Guardian stopped")
        logWatcher?.stop()
        healthTimer?.invalidate()
        uptimeTimer?.invalidate()
        rateLimitTimer?.invalidate()
    }

    private func startRateLimitUpdate() {
        updateRateLimitStatus()
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
        apiErrorStats.reset()
        lastAPIErrorTime = "—"
        lastAPIErrorCategory = .normal
    }

    // MARK: - Private

    private func startLogWatching() {
        logWatcher = LogWatcher()
        logWatcher?.onNewEvents = { [weak self] events in
            guard let self = self else { return }
            DispatchQueue.main.async {
                for event in events {
                    // 使用 ErrorClassifier 统一判断噪音
                    if ErrorClassifier.isNoise(event.message) {
                        continue
                    }

                    // 智能分类
                    let category = ErrorClassifier.classify(event.message)

                    // 创建带分类的事件
                    let classifiedEvent = LogEvent(
                        timestamp: event.timestamp,
                        level: event.level,
                        message: event.message,
                        rawLine: event.rawLine,
                        category: category
                    )

                    self.recentEvents.insert(classifiedEvent, at: 0)
                    if self.recentEvents.count > 100 { self.recentEvents.removeLast() }

                    // 记录 API 错误统计
                    if category != .normal && category != .warning {
                        self.apiErrorStats.record(category)
                        self.lastAPIErrorTime = event.formattedTime
                        self.lastAPIErrorCategory = category
                    }

                    // 仅 Gateway 级别错误触发自动修复
                    self.evaluateStatusForCategory(event, category: category)
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
        let result = await healthChecker.checkWithModelValidation()
        await MainActor.run {
            let newStatus: HealthStatus
            let statusStr: String

            if result.hasConfigMismatch {
                // Model config cleared while Gateway still runs — more severe than crash
                newStatus = .critical
                statusStr = "config_mismatch"
            } else {
                switch result.level {
                case .healthy:
                    newStatus = .healthy
                    statusStr = "healthy"
                case .unhealthy:
                    newStatus = .critical
                    statusStr = "unhealthy"
                case .unknown:
                    newStatus = .unknown
                    statusStr = "unknown"
                }
            }

            // Build error message for mismatches
            let errorMsg: String
            if result.hasConfigMismatch {
                errorMsg = "模型配置异常：声明了 \(result.configuredModelsCount) 个模型但加载了 \(result.modelsCount) 个"
            } else {
                errorMsg = ""
            }

            // Record to SQLite
            self.db.recordHealthCheck(
                status: statusStr,
                responseTimeMs: 0,
                cpuUsage: 0,
                memUsage: 0,
                errorMsg: errorMsg
            )

            if newStatus != self.status {
                let oldStatus = self.status
                self.status = newStatus
                self.onStatusChange?(newStatus)

                // Send Feishu notification if became critical
                if oldStatus != .critical && newStatus == .critical {
                    if result.hasConfigMismatch {
                        self.sendCriticalNotification(
                            message: "模型配置异常：声明了 \(result.configuredModelsCount) 个模型但加载了 \(result.modelsCount) 个"
                        )
                    } else {
                        self.sendCriticalNotification(message: "Gateway 状态异常，进程可能已崩溃")
                    }
                }
            }
        }
    }

    private func updateUptime() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
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

            let lines = output.components(separatedBy: "\n")
            for line in lines {
                let parts = line.trimmingCharacters(in: .whitespaces)
                    .components(separatedBy: .whitespaces)
                    .filter { !$0.isEmpty }
                if parts.count >= 2 {
                    let etime = parts.last ?? ""
                    let pid = parts.first ?? ""
                    if let pidNum = Int(pid), pidNum > 0 {
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

    /// 基于智能分类 + 诊断引擎评估状态（Self-Healing 核心）
    /// 流程：诊断 → 路由修复 → 验证
    private func evaluateStatusForCategory(_ event: LogEvent, category: ErrorCategory) {
        // 如果已经是 critical 状态，不被低级错误降级
        if status == .critical && category != .gatewayCrash && category != .gatewayUnhealthy {
            return
        }

        // 只处理需要关注的错误类别
        guard category != .normal else { return }

        // 收集最近 20 条相关日志作为证据
        let evidenceLines = recentEvents
            .filter { $0.category == category }
            .prefix(20)
            .map { $0.rawLine }

        // Step 1: 诊断 — 分析错误原因和推荐修复动作
        let diagnosis = diagnosisEngine.diagnose(category: category, logLines: evidenceLines)

        // 记录诊断结果（可从 UI 查看）
        let diagnosisSummary = "[\(category.rawValue)] \(diagnosis.cause) | 置信度: \(Int(diagnosis.confidence * 100))% | 动作: \(diagnosis.fixAction.description)"
        print("[Guardian] \(diagnosisSummary)")

        // Step 2: 路由执行 — 根据诊断结果执行对应修复
        Task {
            let fixResult = await fixRouter.executeFix(diagnosis: diagnosis)

            await MainActor.run {
                // 记录修复结果（包装为 HealthStatus.FixResult 用于 UI 显示）
                let fullResult = FixResult(
                    action: "\(diagnosis.category.rawValue): \(fixResult.action)",
                    success: fixResult.success,
                    output: "诊断: \(diagnosis.cause)\n---\n\(fixResult.output)"
                )

                recentFixes.insert(fullResult, at: 0)
                if recentFixes.count > 20 { recentFixes.removeLast() }
                updateRateLimitStatus()

                // Step 3: 根据验证结果更新状态
                switch diagnosis.fixAction {
                case .doNothing, .waitAndRetry:
                    // 自动恢复，不降级状态
                    break

                case .notifyAuthError, .logAndAlert:
                    // 通知类，保持当前状态但记录告警
                    if status == .healthy {
                        status = .warning
                        onStatusChange?(.warning)
                    }

                case .waitAndRetry:
                    break

                default:
                    // 所有需要重启/修复的：验证成功 → healthy，失败 → critical
                    if fixResult.verified {
                        status = .healthy
                        onStatusChange?(.healthy)
                    } else {
                        status = .critical
                        onStatusChange?(.critical)
                    }
                }
            }
        }

        // 立即更新状态（让 UI 即时反馈）
        switch category {
        case .gatewayCrash, .gatewayUnhealthy:
            status = .critical
            onStatusChange?(.critical)
        case .authError, .rateLimit, .overloaded, .pluginError, .networkError:
            if status == .healthy {
                status = .warning
                onStatusChange?(.warning)
            }
        case .warning:
            if status == .healthy {
                status = .warning
                onStatusChange?(.warning)
            }
        case .normal:
            break
        }
    }

    private func sendCriticalNotification(message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        feishuNotifier.notify(
            title: "⚠️ OpenClaw Guardian 检测到故障",
            body: """
            **时间：** \(timestamp)

            **故障原因：** \(message)

            Guardian 正在尝试自动修复。请查看 Menu Bar 了解详情。
            """,
            template: "red"
        )
    }
}
