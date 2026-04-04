import Foundation
import CryptoKit

// MARK: - FixExecutor

/// Executes Gateway self-healing with validated backup, MD5 dedup,
/// fault diagnosis reporting, and SQLite audit logging.
class FixExecutor {
    private let openclawBin = "/opt/homebrew/bin/openclaw"
    private let configPath  = NSHomeDirectory() + "/.openclaw/openclaw.json"
    private let backupDir   = NSHomeDirectory() + "/.openclaw/backups"
    private let reportDir   = NSHomeDirectory() + "/.openclaw/workspace-zhongshu/projects/openclaw-guardian/reports"
    private let latestBackup = NSHomeDirectory() + "/.openclaw/openclaw.json.bak"

    // MARK: - Backup dedup state
    private var lastConfigMD5: String?

    // MARK: - Rate Limit Config
    private let maxAttemptsPerRound = 3
    private let minIntervalBetweenFixes: TimeInterval = 30
    private let rateLimitWindow: TimeInterval = 300

    // MARK: - Rate Limit State
    private var fixHistory: [FixAttempt] = []
    private var lastFixTime: Date?
    private var isRateLimited: Bool = false

    // MARK: - Exponential Backoff
    // backoffMultiplier: 1x → 2x → 4x → 8x (capped), resets on success
    private var backoffMultiplier: Double = 1.0
    private var consecutiveFailures: Int = 0
    private let maxBackoffMultiplier: Double = 8.0  // 8x * 300s = 40min cap (uses 30min hard cap in cooldown calc)
    private let alertAfterConsecutiveFailures: Int = 2

    private let db = DatabaseService.shared

    // MARK: - Public API

    /// Checks if a fix is allowed under rate limiting.
    func canFix() -> (allowed: Bool, reason: String?) {
        let now = Date()
        cleanOldHistory(currentTime: now)

        if isRateLimited {
            if let lastFix = fixHistory.last,
               now.timeIntervalSince(lastFix.timestamp) >= rateLimitWindow {
                isRateLimited = false
                fixHistory.removeAll()
            } else {
                let remaining = Int(rateLimitWindow - now.timeIntervalSince(fixHistory.last?.timestamp ?? now))
                return (false, "已达重启上限（\(maxAttemptsPerRound)次），请等待 \(remaining/60) 分钟后重试")
            }
        }

        // Effective window = base window × backoff multiplier (1x→2x→4x→8x, max 30min)
        let effectiveWindow = min(rateLimitWindow * backoffMultiplier, 1800)
        let recentAttempts = fixHistory.filter { now.timeIntervalSince($0.timestamp) < effectiveWindow }.count
        if recentAttempts >= maxAttemptsPerRound {
            isRateLimited = true
            let waitMinutes = Int(effectiveWindow / 60)
            return (false, "本轮已重启 \(maxAttemptsPerRound) 次，进入冷却期（\(waitMinutes)分钟，\(Int(backoffMultiplier))x退避）")
        }

        if let lastTime = lastFixTime,
           now.timeIntervalSince(lastTime) < minIntervalBetweenFixes {
            let wait = Int(minIntervalBetweenFixes - now.timeIntervalSince(lastTime))
            return (false, "请等待 \(wait) 秒后再试（防抖动）")
        }

        return (true, nil)
    }

    func getRateLimitStatus() -> (attemptsUsed: Int, maxAttempts: Int, isLimited: Bool, nextAvailableIn: Int?) {
        cleanOldHistory(currentTime: Date())
        let recent = fixHistory.filter { Date().timeIntervalSince($0.timestamp) < rateLimitWindow }.count

        var nextAvailable: Int? = nil
        if isRateLimited, let lastFix = fixHistory.last {
            let elapsed = Date().timeIntervalSince(lastFix.timestamp)
            if elapsed < rateLimitWindow {
                nextAvailable = Int(rateLimitWindow - elapsed)
            }
        }
        return (recent, maxAttemptsPerRound, isRateLimited, nextAvailable)
    }

    func fixGateway() async -> FixResult {
        let check = canFix()
        if !check.allowed {
            return FixResult(
                action: "修复被拒绝",
                success: false,
                output: "限流原因: \(check.reason ?? "未知")"
            )
        }

        // Step 1: Check if process is alive (using lsof on port 18789)
        let healthChecker = HealthChecker()
        let processAlive = healthChecker.isProcessAlive()

        if !processAlive {
            // Process is dead → use restartGatewayProcess() instead of restartGateway()
            return await restartGatewayProcess()
        }

        // Step 2: Process is alive but health check failed → use original restart logic (config issue)
        let level = await healthChecker.check()

        switch level {
        case .healthy:
            return FixResult(action: "健康检查", success: true, output: "Gateway 运行正常，无需修复")
        case .unhealthy:
            return await restartGateway(reason: "unhealthy (health check failed)")
        case .unknown:
            return await restartGateway(reason: "unknown status")
        }
    }

    // MARK: - Restart

    private func checkGatewayRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-ax", "-o", "comm=", "-c"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }
        return output.contains("openclaw-gateway") || output.contains("openclaw")
    }

    /// Restarts the gateway process when it's dead (not running).
    /// Executes `openclaw gateway start` and waits for health to become healthy.
    func restartGatewayProcess() async -> FixResult {
        var outputLines: [String] = []
        outputLines.append("检测到进程已死亡，尝试拉起...")

        // Execute `openclaw gateway start` to bring up the process
        let startTask = Process()
        startTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        startTask.arguments = ["-c", "\(openclawBin) gateway start 2>&1"]
        let pipe = Pipe()
        startTask.standardOutput = pipe
        startTask.standardError = pipe
        try? startTask.run()
        startTask.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        outputLines.append("启动输出: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Wait for health to become healthy (max 30 seconds, check every 3 seconds)
        let healthChecker = HealthChecker()
        var waitedSeconds = 0
        var success = false

        while waitedSeconds < 30 {
            try? await Task.sleep(nanoseconds: 3_000_000_000)  // 3 seconds
            waitedSeconds += 3

            let level = await healthChecker.check()
            if level == .healthy {
                success = true
                outputLines.append("进程已拉起，健康检查通过 (等待 \(waitedSeconds)s)")
                break
            }
            outputLines.append("等待健康检查... (\(waitedSeconds)s/30s)")
        }

        if !success {
            outputLines.append("⚠️ 进程已启动但健康检查未通过")
        }

        // Record attempt
        let attempt = FixAttempt(timestamp: Date(), reason: "process_dead", success: success)
        fixHistory.append(attempt)
        lastFixTime = Date()

        // SQLite audit
        db.recordHealEvent(
            reason: "process_dead",
            method: "start",
            result: success ? "success" : "failed",
            reportPath: nil as String?
        )

        if success {
            consecutiveFailures = 0
            backoffMultiplier = 1.0
        } else {
            consecutiveFailures += 1
            backoffMultiplier = min(backoffMultiplier * 2, maxBackoffMultiplier)
            db.recordSystemEvent(eventType: "heal_failed", message: "process_dead")
        }

        return FixResult(
            action: "拉起 Gateway 进程 (process_dead)",
            success: success,
            output: outputLines.joined(separator: "\n")
        )
    }

    private func restartGateway(reason: String) async -> FixResult {
        var outputLines: [String] = []
        outputLines.append("原因: \(reason)")

        // Before restarting: backup validated config
        let backupResult = backupConfig()
        if !backupResult.isEmpty {
            outputLines.append("备份: \(backupResult)")
        }

        // Save error config for report
        let errSaved = saveErrorConfig()
        if !errSaved.isEmpty {
            outputLines.append("错误配置已保存至: \(errSaved)")
        }

        // Restart
        let restartTask = Process()
        restartTask.executableURL = URL(fileURLWithPath: "/bin/bash")
        restartTask.arguments = ["-c", "\(openclawBin) gateway restart 2>&1"]
        let pipe = Pipe()
        restartTask.standardOutput = pipe
        restartTask.standardError = pipe
        try? restartTask.run()
        restartTask.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        outputLines.append("重启输出: \(output.trimmingCharacters(in: .whitespacesAndNewlines))")

        // Verify health
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let healthChecker = HealthChecker()
        let newLevel = await healthChecker.check()
        let success = newLevel == .healthy
        outputLines.append("重启后状态: \(newLevel)")

        // Generate fault report if we backed up
        var reportPath = ""
        if !backupResult.isEmpty {
            reportPath = generateFaultReport(
                configPath: errSaved,
                backupPath: latestBackup,
                reason: reason
            )
            if !reportPath.isEmpty {
                outputLines.append("故障报告: \(reportPath)")
            }
        }

        // Record attempt
        let attempt = FixAttempt(timestamp: Date(), reason: reason, success: success)
        fixHistory.append(attempt)
        lastFixTime = Date()

        // SQLite audit
        db.recordHealEvent(
            reason: reason,
            method: "restart",
            result: success ? "success" : "failed",
            reportPath: reportPath.isEmpty ? nil : reportPath
        )

        // Alert if still failing
        if !success {
            consecutiveFailures += 1
            backoffMultiplier = min(backoffMultiplier * 2, maxBackoffMultiplier)
            db.recordSystemEvent(eventType: "heal_failed", message: reason)

            // Alert user via Feishu after 2 consecutive failures
            if consecutiveFailures >= alertAfterConsecutiveFailures {
                let feishuNotifier = FeishuNotifier()
                feishuNotifier.notifyError(
                    title: "🚨 Guardian 修复连续失败",
                    body: "Gateway 已连续失败 **\(consecutiveFailures) 次**，当前退避倍数：**\(Int(backoffMultiplier))x**（等待 \(Int(min(rateLimitWindow * backoffMultiplier, 1800) / 60)) 分钟）\n\n最近失败原因：\(reason)"
                )
                outputLines.append("🚨 已发送飞书告警通知（连续 \(consecutiveFailures) 次失败）")
            }
        } else {
            // Reset on success
            consecutiveFailures = 0
            backoffMultiplier = 1.0
        }

        // Rate limit check (uses effectiveWindow = base * backoffMultiplier)
        let effectiveWindow = min(rateLimitWindow * backoffMultiplier, 1800)
        let recentFailures = fixHistory
            .filter { Date().timeIntervalSince($0.timestamp) < effectiveWindow }
            .filter { !$0.success }
            .count
        if recentFailures >= maxAttemptsPerRound {
            isRateLimited = true
            outputLines.append("⚠️ 已连续失败 \(maxAttemptsPerRound) 次，进入冷却期（\(Int(effectiveWindow/60))分钟，\(Int(backoffMultiplier))x退避）")
        }

        return FixResult(
            action: "重启 Gateway (\(reason))",
            success: success,
            output: outputLines.joined(separator: "\n")
        )
    }

    // MARK: - Validated Backup

    /// Performs a validated backup:
    /// 1. Runs `openclaw health` to verify config is valid before backing up
    /// 2. Computes current config MD5; skips if unchanged from last backup
    /// 3. Keeps up to 5 timestamped backups + one `openclaw.json.bak`
    /// Returns a description of what was done.
    @discardableResult
    func backupConfig() -> String {
        // Step 1: validate with openclaw health
        guard validateConfigWithHealth() else {
            print("[FixExecutor] Config invalid (openclaw health failed); skipping backup.")
            return ""
        }

        // Step 2: read current config
        guard FileManager.default.fileExists(atPath: configPath),
              let currentData = FileManager.default.contents(atPath: configPath),
              let currentContent = String(data: currentData, encoding: .utf8) else {
            return ""
        }

        // Step 3: MD5 dedup
        let currentMD5 = md5(currentContent)
        if currentMD5 == lastConfigMD5 {
            print("[FixExecutor] Config MD5 unchanged; skipping backup.")
            return ""
        }

        // Step 4: ensure backup dir
        let fm = FileManager.default
        try? fm.createDirectory(atPath: backupDir, withIntermediateDirectories: true)

        // Step 5: rotate backups (keep 5)
        rotateBackups(keep: 5)

        // Step 6: save timestamped backup
        let timestamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        let tsBackup = backupDir + "/openclaw.\(timestamp).json.bak"
        try? currentData.write(to: URL(fileURLWithPath: tsBackup))

        // Step 7: save as latest validated backup
        try? currentData.write(to: URL(fileURLWithPath: latestBackup))

        lastConfigMD5 = currentMD5
        print("[FixExecutor] Backed up config to \(tsBackup)")

        DatabaseService.shared.recordSystemEvent(
            eventType: "config_backup",
            message: "Validated backup saved to \(tsBackup)"
        )

        return tsBackup
    }

    /// Checks config validity by running `openclaw health`.
    private func validateConfigWithHealth() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/bash")
        task.arguments = ["-c", "\(openclawBin) health 2>&1"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        // Exit code 0 + non-empty output = healthy
        return task.terminationStatus == 0 && !output.isEmpty
    }

    /// Rotates backups in backupDir, keeping `keep` most recent.
    private func rotateBackups(keep: Int) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: backupDir) else { return }

        let backups = files
            .filter { $0.hasPrefix("openclaw.") && $0.hasSuffix(".json.bak") }
            .map { filename -> (String, Date) in
                let full = (backupDir as NSString).appendingPathComponent(filename)
                let mod = (try? fm.attributesOfItem(atPath: full)[.modificationDate] as? Date) ?? Date.distantPast
                return (filename, mod)
            }
            .sorted { $0.1 > $1.1 }

        // Remove excess
        for entry in backups.dropFirst(keep) {
            try? fm.removeItem(atPath: (backupDir as NSString).appendingPathComponent(entry.0))
        }
    }

    // MARK: - Error Config Save

    /// Saves the current (potentially bad) config to openclaw.json.err for diagnosis.
    func saveErrorConfig() -> String {
        let errPath = NSHomeDirectory() + "/.openclaw/openclaw.json.err"
        if FileManager.default.fileExists(atPath: configPath) {
            try? FileManager.default.copyItem(atPath: configPath, toPath: errPath)
        }
        return errPath
    }

    // MARK: - Fault Report

    /// Generates a Markdown fault diagnosis report comparing the bad config
    /// against the validated backup, then saves it to reportDir.
    /// Returns the path to the generated report, or "" on failure.
    @discardableResult
    func generateFaultReport(configPath: String, backupPath: String, reason: String) -> String {
        let fm = FileManager.default

        // Ensure report dir
        try? fm.createDirectory(atPath: reportDir, withIntermediateDirectories: true)

        let timestamp = ISO8601DateFormatter().string(from: Date())
        let safeTimestamp = timestamp.replacingOccurrences(of: ":", with: "-")
        let reportFile = reportDir + "/fault-\(safeTimestamp).md"

        // Read files
        let errContent  = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? "[无法读取错误配置]"
        let bakContent  = (try? String(contentsOfFile: backupPath, encoding: .utf8)) ?? "[无法读取备份配置]"

        // Compute line-level diff
        let errLines = errContent.components(separatedBy: .newlines)
        let bakLines = bakContent.components(separatedBy: .newlines)
        let diffLines = computeLineDiff(original: errLines, fixed: bakLines)

        // Build markdown
        let md = """
        # 🔍 OpenClaw Guardian 故障诊断报告

        **时间:** \(timestamp)
        **故障原因:** \(reason)
        **错误配置:** `\(configPath)`
        **健康备份:** `\(backupPath)`

        ---

        ## 📊 配置对比 (Diff)

        ```
        \(diffLines.isEmpty ? "(无差异)" : diffLines)
        ```

        ---

        ## 📁 原始错误配置

        <details>
        <summary>点击展开 / 收起</summary>

        ```
        \(errContent)
        ```

        </details>

        ---

        ## ✅ 健康备份配置

        <details>
        <summary>点击展开 / 收起</summary>

        ```
        \(bakContent)
        ```

        </details>

        ---

        *由 OpenClaw Guardian 自动生成*
        """

        // Write report
        try? md.write(toFile: reportFile, atomically: true, encoding: .utf8)

        DatabaseService.shared.recordSystemEvent(
            eventType: "fault_report_generated",
            message: "Report saved to \(reportFile)"
        )

        return reportFile
    }

    /// Simple line-level diff: returns lines that differ between original and fixed.
    private func computeLineDiff(original: [String], fixed: [String]) -> String {
        let origSet  = Set(original)
        let fixedSet = Set(fixed)

        var removed = origSet.subtracting(fixedSet)
        var added   = fixedSet.subtracting(origSet)

        var lines: [String] = []
        for line in original {
            if removed.contains(line) {
                lines.append("- \(line)")
                removed.remove(line)
            }
        }
        for line in fixed {
            if added.contains(line) {
                lines.append("+ \(line)")
                added.remove(line)
            }
        }
        return lines.isEmpty ? "(配置完全相同)" : lines.joined(separator: "\n")
    }

    // MARK: - MD5

    private func md5(_ string: String) -> String {
        let data = Data(string.utf8)
        let hash = Insecure.MD5.hash(data: data)
        return hash.map { String(format: "%02hhx", $0) }.joined()
    }

    // MARK: - Private Helpers

    private func cleanOldHistory(currentTime: Date) {
        fixHistory.removeAll { currentTime.timeIntervalSince($0.timestamp) >= rateLimitWindow }
    }
}

// MARK: - FixAttempt

struct FixAttempt {
    let timestamp: Date
    let reason: String
    let success: Bool
}
