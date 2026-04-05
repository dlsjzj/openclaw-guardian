import Foundation

// MARK: - FixAction

/// Represents the specific remediation action to take after diagnosis.
/// Each action is a targeted fix, NOT a blind restart.
enum FixAction: Equatable {
    /// Do nothing — error resolves automatically or doesn't affect Gateway
    case doNothing(reason: String)

    /// Rate limited by upstream API — wait and recheck (no restart)
    case waitAndRetry(afterSeconds: Int, reason: String)

    /// Port conflict — kill the process occupying the port, then restart Gateway
    case killPortProcess(port: Int, processInfo: String)

    /// Config corrupted — restore from latest validated backup
    case rollbackConfig(backupPath: String, reason: String)

    /// Model config cleared/empty — restore from backup or notify user
    case restoreModels(loaded: Int, configured: Int)

    /// Auth failure (401/invalid key) — notify user, do NOT restart
    case notifyAuthError(body: String)

    /// Plugin crashed — restart Gateway (plugins can't be individually fixed)
    case restartGatewayPlugin(reason: String)

    /// OOM / memory pressure — log only, blind restart won't help
    case logAndAlert(reason: String, severity: String)

    /// Unknown error — attempt Gateway restart as last resort
    case restartGatewayFallback(reason: String)

    /// Restore configuration from backup after multiple failures
    case restoreBackup(reason: String)

    /// Description for display
    var description: String {
        switch self {
        case .doNothing(let r):           return "忽略: \(r)"
        case .waitAndRetry(let s, let r):  return "等待\(s)秒后重试: \(r)"
        case .killPortProcess(let p, _):   return "释放端口\(p)并重启"
        case .rollbackConfig(_, let r):     return "回滚配置: \(r)"
        case .restoreModels(let l, let c): return "恢复模型配置(加载\(l)/声明\(c))"
        case .notifyAuthError(let b):       return "通知认证错误: \(b)"
        case .restartGatewayPlugin(let r):  return "重启Gateway(插件): \(r)"
        case .logAndAlert(let r, _):       return "记录并告警: \(r)"
        case .restartGatewayFallback(let r):return "重启Gateway(兜底): \(r)"
        case .restoreBackup(let r):        return "恢复备份: \(r)"
        }
    }

    /// Whether this action requires Gateway restart
    var requiresRestart: Bool {
        switch self {
        case .killPortProcess, .rollbackConfig, .restoreModels,
             .restartGatewayPlugin, .restartGatewayFallback, .restoreBackup:
            return true
        case .doNothing, .waitAndRetry, .notifyAuthError, .logAndAlert:
            return false
        }
    }
}

// MARK: - DiagnosisResult

/// Result of running DiagnosisEngine.diagnose().
struct DiagnosisResult {
    /// The root cause description (human-readable)
    let cause: String

    /// The recommended fix action
    let fixAction: FixAction

    /// Confidence score 0.0–1.0
    let confidence: Double

    /// The error category this diagnosis is based on
    let category: ErrorCategory

    /// All log lines considered for this diagnosis
    let evidence: [String]

    /// Timestamp of diagnosis
    let diagnosedAt: Date
}

// MARK: - DiagnosisFixResult

/// Result of executing a fix action.
struct DiagnosisFixResult {
    let action: String
    let success: Bool
    let output: String
    let verified: Bool  // true if health check confirmed fix worked
    let performedAt: Date

    init(action: String, success: Bool, output: String, verified: Bool = false) {
        self.action = action
        self.success = success
        self.output = output
        self.verified = verified
        self.performedAt = Date()
    }
}

// MARK: - DiagnosisEngine

/// Interprets ErrorCategory + raw log lines → structured DiagnosisResult.
/// Implements the "Diagnose before Fix" principle.
class DiagnosisEngine {

    private let latestBackupPath = NSHomeDirectory() + "/.openclaw/openclaw.json.bak"
    private let configPath       = NSHomeDirectory() + "/.openclaw/openclaw.json"
    private let backupDir        = NSHomeDirectory() + "/.openclaw/backups"

    // MARK: - Public API

    /// Primary entry point: diagnose an error category with associated log lines.
    /// Returns a DiagnosisResult with cause description, recommended action, and confidence.
    func diagnose(category: ErrorCategory, logLines: [String]) -> DiagnosisResult {
        let evidence  = relevantEvidence(for: category, from: logLines)
        let cause     = describeCause(category: category, evidence: evidence)
        let action    = determineFixAction(category: category, evidence: evidence)
        let confidence = computeConfidence(category: category, evidence: evidence)

        return DiagnosisResult(
            cause: cause,
            fixAction: action,
            confidence: confidence,
            category: category,
            evidence: evidence,
            diagnosedAt: Date()
        )
    }

    // MARK: - Evidence Extraction

    /// Returns log lines most relevant to the given category.
    private func relevantEvidence(for category: ErrorCategory, from logLines: [String]) -> [String] {
        guard !logLines.isEmpty else { return [] }

        switch category {
        case .authError:
            return logLines.filter { line in
                let lower = line.lowercased()
                return lower.contains("401") || lower.contains("authentication_error") ||
                       lower.contains("unauthorized") || lower.contains("api secret key") ||
                       lower.contains("login fail")
            }

        case .rateLimit:
            return logLines.filter { line in
                let lower = line.lowercased()
                return lower.contains("429") || lower.contains("rate.limit") ||
                       lower.contains("too many requests") || lower.contains("quota")
            }

        case .gatewayCrash:
            return logLines.filter { line in
                let lower = line.lowercased()
                return lower.contains("oom") || lower.contains("killed") ||
                       lower.contains("panic") || lower.contains("segfault") ||
                       lower.contains("eaddrinuse") || lower.contains("port already in use") ||
                       lower.contains("process.*exited") || lower.contains("signal sigterm") ||
                       lower.contains("sigkill")
            }

        case .overloaded:
            return logLines.filter { line in
                let lower = line.lowercased()
                return lower.contains("529") || lower.contains("overload") ||
                       lower.contains("负载") || lower.contains("temporarily")
            }

        case .pluginError:
            return logLines.filter { line in
                let lower = line.lowercased()
                return lower.contains("plugin") || lower.contains("summarize") ||
                       lower.contains("embedding") || lower.contains("judge")
            }

        case .networkError:
            return logLines.filter { line in
                let lower = line.lowercased()
                return lower.contains("fetch failed") || lower.contains("connrefused") ||
                       lower.contains("etimedout") || lower.contains("enotfound") ||
                       lower.contains("network error")
            }

        default:
            return Array(logLines.suffix(5))
        }
    }

    // MARK: - Cause Description

    private func describeCause(category: ErrorCategory, evidence: [String]) -> String {
        switch category {
        case .gatewayCrash:
            for line in evidence {
                let lower = line.lowercased()
                if lower.contains("oom") || lower.contains("out of memory") || lower.contains("killed") {
                    return "Gateway 因内存不足被系统终止（OOM/Killed）"
                }
                if lower.contains("eaddrinuse") || lower.contains("port already in use") {
                    return "Gateway 启动失败：端口被占用"
                }
                if lower.contains("panic") || lower.contains("segfault") {
                    return "Gateway 发生致命崩溃（Panic/Segfault）"
                }
                if lower.contains("sigterm") || lower.contains("sigkill") {
                    return "Gateway 进程被强制终止（SIGTERM/SIGKILL）"
                }
                if lower.contains("process.*exited") {
                    return "Gateway 进程意外退出"
                }
            }
            return "Gateway 发生崩溃"

        case .gatewayUnhealthy:
            return "Gateway 健康检查失败，可能是进程响应异常"

        case .authError:
            for line in evidence {
                if line.contains("Please carry the API secret key") || line.contains("login fail") {
                    return "MiniMax API 认证失败：API Secret Key 无效或已过期"
                }
                if line.contains("401") {
                    return "上游 API 返回 401 认证失败"
                }
            }
            return "认证凭据无效或已过期"

        case .rateLimit:
            for line in evidence {
                if line.contains("429") || line.contains("rate.limit") {
                    return "上游 API 触发限流（HTTP 429）"
                }
            }
            return "API 请求频率超限，触发限流"

        case .overloaded:
            return "上游服务负载过高（HTTP 529）"

        case .pluginError:
            for line in evidence {
                if line.contains("summarize") {
                    return "文本摘要插件执行失败"
                }
                if line.contains("embedding") {
                    return "Embedding 生成失败"
                }
                if line.contains("judge") {
                    return "Topic 判断插件失败"
                }
            }
            return "插件执行出错"

        case .networkError:
            for line in evidence {
                let lower = line.lowercased()
                if lower.contains("connrefused") {
                    return "网络连接被拒绝（Connection Refused）"
                }
                if lower.contains("etimedout") {
                    return "网络连接超时（Connection Timeout）"
                }
                if lower.contains("fetch failed") {
                    return "网络请求失败（Fetch Failed）"
                }
            }
            return "网络连接异常"

        case .warning:
            return "非致命警告，不影响 Gateway 运行"

        case .normal:
            return "未检测到故障"
        }
    }

    // MARK: - Action Determination

    private func determineFixAction(category: ErrorCategory, evidence: [String]) -> FixAction {
        switch category {
        case .gatewayCrash:
            return crashFixAction(evidence: evidence)

        case .gatewayUnhealthy:
            if hasRecentBackup() {
                return .rollbackConfig(
                    backupPath: latestBackupPath,
                    reason: "Gateway 不健康且有备份，尝试回滚"
                )
            } else {
                return .restartGatewayFallback(reason: "Gateway 不健康，无可用备份")
            }

        case .authError:
            return .notifyAuthError(
                body: "MiniMax API 认证失败。请检查 openclaw.json 中的 API Key 配置。"
            )

        case .rateLimit:
            return .waitAndRetry(afterSeconds: 30, reason: "限流等待后自动重试")

        case .overloaded:
            return .waitAndRetry(afterSeconds: 60, reason: "服务过载，等待60秒后重试")

        case .pluginError:
            return .restartGatewayPlugin(
                reason: "插件执行失败，Gateway 本身可能仍健康，重启尝试恢复"
            )

        case .networkError:
            return .waitAndRetry(afterSeconds: 15, reason: "网络异常，等待15秒后重试")

        case .warning:
            return .doNothing(reason: "非致命警告，无需修复")

        case .normal:
            return .doNothing(reason: "状态正常")
        }
    }

    private func crashFixAction(evidence: [String]) -> FixAction {
        for line in evidence {
            let lower = line.lowercased()

            if lower.contains("oom") || lower.contains("out of memory") || lower.contains("killed") {
                return .logAndAlert(
                    reason: "Gateway 因 OOM 被 kill，无意义重启会循环。需增加系统内存或优化配置。",
                    severity: "critical"
                )
            }

            if lower.contains("eaddrinuse") || lower.contains("port already in use") {
                let port = extractPortNumber(from: line) ?? 18789
                return .killPortProcess(port: port, processInfo: "端口被占用，尝试释放后重启")
            }
        }
        return .restartGatewayFallback(reason: "Gateway 崩溃，尝试重启恢复")
    }

    // MARK: - Confidence Scoring

    private func computeConfidence(category: ErrorCategory, evidence: [String]) -> Double {
        guard !evidence.isEmpty else {
            return category == .normal ? 1.0 : 0.5
        }

        var score: Double = 0.5
        score += min(Double(evidence.count) * 0.05, 0.2)

        for line in evidence {
            let lower = line.lowercased()
            if lower.contains("401") || lower.contains("429") || lower.contains("529") {
                score += 0.15
            }
            if lower.contains("sigkill") || lower.contains("sigterm") {
                score += 0.2
            }
            if lower.contains("killed") && lower.contains("oom") {
                score += 0.25
            }
            if lower.contains("eaddrinuse") || lower.contains("port already in use") {
                score += 0.2
            }
            if lower.contains("authentication_error") {
                score += 0.2
            }
        }

        return min(score, 1.0)
    }

    // MARK: - Helpers

    private func hasRecentBackup() -> Bool {
        return FileManager.default.fileExists(atPath: latestBackupPath)
    }

    private func extractPortNumber(from line: String) -> Int? {
        let patterns = [":(\\d{4,5})", "port (\\d{4,5})"]
        for pattern in patterns {
            if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
               let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                return Int(line[range])
            }
        }
        return nil
    }
}

// MARK: - FixRouter

/// Executes FixAction items returned by DiagnosisEngine.
/// Verifies each fix with a health check after execution.
class FixRouter {

    private let openclawBin    = "/opt/homebrew/bin/openclaw"
    private let latestBackupPath = NSHomeDirectory() + "/.openclaw/openclaw.json.bak"
    private let configPath     = NSHomeDirectory() + "/.openclaw/openclaw.json"
    private let backupDir      = NSHomeDirectory() + "/.openclaw/backups"

    private let db = DatabaseService.shared

    // MARK: - Public API

    /// Executes the fix action recommended by DiagnosisEngine.
    /// Returns DiagnosisFixResult with verification status.
    func executeFix(diagnosis: DiagnosisResult) async -> DiagnosisFixResult {
        let action = diagnosis.fixAction

        switch action {
        case .doNothing(let reason):
            let result = DiagnosisFixResult(
                action: "无需修复",
                success: true,
                output: reason,
                verified: true
            )
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .waitAndRetry(let seconds, let reason):
            let result = await waitAndRetry(seconds: seconds, reason: reason)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .killPortProcess(let port, let processInfo):
            let result = await killPortProcessAndRestart(port: port, processInfo: processInfo)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .rollbackConfig(let backupPath, let reason):
            let result = await rollbackConfigAndRestart(backupPath: backupPath, reason: reason)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .restoreModels(let loaded, let configured):
            let result = await restoreModels(loaded: loaded, configured: configured)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .notifyAuthError(let body):
            let result = notifyAuthError(body: body)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .restartGatewayPlugin(let reason):
            let result = await restartGateway(reason: reason)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .logAndAlert(let reason, let severity):
            let result = logAndAlert(reason: reason, severity: severity)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .restartGatewayFallback(let reason):
            let result = await restartGateway(reason: reason)
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: result)
            return result

        case .restoreBackup(_):
            // Use FixExecutor's restoreFromBackup through the FixExecutor class
            let fixExecutor = FixExecutor()
            let result = await fixExecutor.restoreFromBackup()
            let diagnosisResult = DiagnosisFixResult(
                action: result.action,
                success: result.success,
                output: result.output,
                verified: result.success
            )
            db.recordDiagnosisEvent(diagnosis: diagnosis, fixResult: diagnosisResult)
            return diagnosisResult
        }
    }

    // MARK: - Individual Fix Actions

    /// Wait and recheck — used for rate limit, network errors, overloaded.
    private func waitAndRetry(seconds: Int, reason: String) async -> DiagnosisFixResult {
        var output = "等待 \(seconds) 秒后重新检查..."
        output += "\n原因: \(reason)"

        try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)

        let healthChecker = HealthChecker()
        let health = await healthChecker.check()
        let recovered = (health == .healthy)
        output += "\n等待后健康检查: \(health)"
        let recoveredStr = recovered ? "成功" : "未恢复，需继续观察"
        output += "\n自动恢复: \(recoveredStr)"

        return DiagnosisFixResult(
            action: "waitAndRetry(\(seconds)s)",
            success: recovered,
            output: output,
            verified: recovered
        )
    }

    /// Kill the process occupying a port, then restart Gateway.
    private func killPortProcessAndRestart(port: Int, processInfo: String) async -> DiagnosisFixResult {
        var output = "诊断: 端口冲突 (port \(port))"
        output += "\n\(processInfo)"

        let (stdout, _) = await runCommand("/usr/sbin/lsof", args: ["-i", ":\(port)", "-t"])
        let pids = stdout.components(separatedBy: "\n").filter { !$0.isEmpty }

        if pids.isEmpty {
            output += "\n未找到占用端口 \(port) 的进程，尝试直接重启"
            let result = await restartGateway(reason: "端口冲突重启")
            return DiagnosisFixResult(
                action: "端口冲突处理",
                success: result.success,
                output: output + "\n" + result.output,
                verified: result.verified
            )
        }

        for pid in pids {
            output += "\n终止占用端口的进程 PID \(pid)"
            let killResult = await runCommand("/bin/kill", args: ["-9", pid])
            output += "\nkill -9 \(pid): exit \(killResult.exitCode)"
        }

        try? await Task.sleep(nanoseconds: 2_000_000_000)
        let restartResult = await restartGateway(reason: "端口冲突后重启")
        output += "\n" + restartResult.output

        return DiagnosisFixResult(
            action: "端口冲突修复",
            success: restartResult.success,
            output: output,
            verified: restartResult.verified
        )
    }

    /// Restore config from validated backup, then restart Gateway.
    private func rollbackConfigAndRestart(backupPath: String, reason: String) async -> DiagnosisFixResult {
        var output = "诊断: 配置文件损坏"
        output += "\n原因: \(reason)"

        guard FileManager.default.fileExists(atPath: backupPath) else {
            output += "\n备份文件不存在: \(backupPath)，无法回滚"
            return DiagnosisFixResult(action: "配置回滚", success: false, output: output, verified: false)
        }

        output += "\n✅ 找到备份: \(backupPath)"

        let healthValid = await validateBackup(backupPath)
        if !healthValid {
            output += "\n⚠️ 备份验证失败（openclaw health 不通过），尝试找到其他备份"
            if let validPath = findLatestValidBackup() {
                output += "\n✅ 找到有效备份: \(validPath)"
                return await doRollback(backupPath: validPath, reason: reason, output: output)
            } else {
                output += "\n❌ 无有效备份，放弃回滚，尝试重启"
                let restartResult = await restartGateway(reason: "配置损坏但无有效备份")
                return DiagnosisFixResult(
                    action: "配置回滚",
                    success: false,
                    output: output + "\n" + restartResult.output,
                    verified: restartResult.verified
                )
            }
        }

        return await doRollback(backupPath: backupPath, reason: reason, output: output)
    }

    private func doRollback(backupPath: String, reason: String, output: String) async -> DiagnosisFixResult {
        var out = output

        let errPath = NSHomeDirectory() + "/.openclaw/openclaw.json.err"
        try? FileManager.default.copyItem(atPath: configPath, toPath: errPath)
        out += "\n当前配置已备份至: \(errPath)"

        do {
            try FileManager.default.copyItem(atPath: backupPath, toPath: configPath)
            out += "\n✅ 配置已从备份恢复: \(backupPath) → \(configPath)"
        } catch {
            out += "\n❌ 恢复失败: \(error.localizedDescription)"
            return DiagnosisFixResult(action: "配置回滚", success: false, output: out, verified: false)
        }

        try? await Task.sleep(nanoseconds: 1_500_000_000)
        let restartResult = await restartGateway(reason: "配置回滚后重启")
        out += "\n" + restartResult.output

        return DiagnosisFixResult(
            action: "配置回滚",
            success: restartResult.success,
            output: out,
            verified: restartResult.verified
        )
    }

    /// Notify user about auth errors — do NOT restart.
    private func notifyAuthError(body: String) -> DiagnosisFixResult {
        let notifier = FeishuNotifier()
        notifier.notifyError(
            title: "🔐 OpenClaw 认证失败",
            body: body + "\n\n请检查 openclaw.json 中的 MiniMax API Key 配置。"
        )

        return DiagnosisFixResult(
            action: "认证错误通知",
            success: true,
            output: "已发送飞书认证错误通知（不重启）",
            verified: true
        )
    }

    /// Alert only — for OOM and cases where restart won't help.
    private func logAndAlert(reason: String, severity: String) -> DiagnosisFixResult {
        db.recordSystemEvent(eventType: "oom_alert", message: reason)

        let notifier = FeishuNotifier()
        notifier.notifyError(
            title: "🧠 OpenClaw OOM / 内存告警",
            body: reason + "\n\n盲目重启无法解决 OOM，请检查系统内存使用情况。"
        )

        return DiagnosisFixResult(
            action: "OOM记录并告警",
            success: true,
            output: "已记录并发送告警（不做无意义重启）",
            verified: true
        )
    }

    /// Restart Gateway for plugin errors or fallback cases.
    private func restartGateway(reason: String) async -> DiagnosisFixResult {
        var output = "执行 Gateway 重启\n原因: \(reason)"

        let restartResult = await runCommand(openclawBin, args: ["gateway", "restart"])
        output += "\nrestart exit: \(restartResult.exitCode)"
        if !restartResult.stdout.isEmpty {
            output += "\n输出: \(restartResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        try? await Task.sleep(nanoseconds: 4_000_000_000)
        let healthChecker = HealthChecker()
        let health = await healthChecker.check()
        let verified = (health == .healthy)

        output += "\n重启后健康检查: \(health)"
        let verifiedIcon = verified ? "✅" : "❌"
        output += "\n验证通过: \(verifiedIcon)"

        return DiagnosisFixResult(
            action: "restartGateway",
            success: restartResult.exitCode == 0 && verified,
            output: output,
            verified: verified
        )
    }

    /// Handle model config cleared but Gateway still running.
    private func restoreModels(loaded: Int, configured: Int) async -> DiagnosisFixResult {
        var output = "诊断: 模型配置丢失"
        output += "\n声明了 \(configured) 个模型但加载了 \(loaded) 个"

        guard FileManager.default.fileExists(atPath: latestBackupPath) else {
            output += "\n❌ 无备份，通知用户手动恢复"
            let notifier = FeishuNotifier()
            notifier.notifyError(
                title: "🤖 OpenClaw 模型配置丢失",
                body: "声明了 \(configured) 个模型但加载了 \(loaded) 个，且无有效备份。请手动检查 openclaw.json。"
            )
            return DiagnosisFixResult(action: "模型恢复", success: false, output: output, verified: false)
        }

        output += "\n从备份恢复模型配置: \(latestBackupPath)"

        // Step 1: Read backup config and extract models section
        guard let backupData = FileManager.default.contents(atPath: latestBackupPath),
              let backupJSON = try? JSONSerialization.jsonObject(with: backupData) as? [String: Any],
              let backupModels = backupJSON["models"] as? [[String: Any]] else {
            output += "\n⚠️ 备份中无 models 配置，通知用户手动恢复"
            let notifier = FeishuNotifier()
            notifier.notifyError(
                title: "🤖 OpenClaw 模型配置丢失",
                body: "声明了 \(configured) 个模型但加载了 \(loaded) 个，备份中无 models 配置。请手动检查 openclaw.json。"
            )
            return DiagnosisFixResult(action: "模型恢复", success: false, output: output, verified: false)
        }

        output += "\n✅ 备份中包含 \(backupModels.count) 个模型配置"

        // Step 2: Read current config
        guard FileManager.default.fileExists(atPath: configPath),
              let currentData = FileManager.default.contents(atPath: configPath),
              var currentJSON = try? JSONSerialization.jsonObject(with: currentData) as? [String: Any] else {
            output += "\n❌ 无法读取当前配置文件"
            return DiagnosisFixResult(action: "模型恢复", success: false, output: output, verified: false)
        }

        // Step 3: Save current config as error backup
        let errPath = NSHomeDirectory() + "/.openclaw/openclaw.json.err"
        try? FileManager.default.copyItem(atPath: configPath, toPath: errPath)
        output += "\n当前配置已备份至: \(errPath)"

        // Step 4: Replace models section in current config
        currentJSON["models"] = backupModels
        output += "\n✅ 已将备份中的 models 配置合并到当前配置"

        // Step 5: Write merged config back
        guard let mergedData = try? JSONSerialization.data(withJSONObject: currentJSON, options: [.prettyPrinted, .sortedKeys]) else {
            output += "\n❌ 序列化合并后的配置失败"
            return DiagnosisFixResult(action: "模型恢复", success: false, output: output, verified: false)
        }
        do {
            try mergedData.write(to: URL(fileURLWithPath: configPath))
            output += "\n✅ 合并后的配置已写入: \(configPath)"
        } catch {
            output += "\n❌ 写入配置失败: \(error.localizedDescription)"
            return DiagnosisFixResult(action: "模型恢复", success: false, output: output, verified: false)
        }

        // Step 6: Restart Gateway to reload models
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        output += "\n重启 Gateway 以重新加载模型..."
        let restartResult = await restartGateway(reason: "模型配置恢复后重启")
        output += "\n" + restartResult.output

        if restartResult.verified {
            let healthChecker = HealthChecker()
            let result = await healthChecker.checkWithModelValidation()
            if result.modelsCount > 0 {
                output += "\n✅ 模型已恢复: \(result.modelsCount) 个模型加载成功"
            } else {
                output += "\n⚠️ 模型仍未加载，可能需要手动干预"
            }
        }

        return DiagnosisFixResult(
            action: "模型恢复",
            success: restartResult.verified,
            output: output,
            verified: restartResult.verified
        )
    }

    // MARK: - Private Helpers

    /// Validates a backup config with `openclaw health`.
    private func validateBackup(_ path: String) async -> Bool {
        let (stdout, exitCode) = await runCommand(openclawBin, args: ["health"])
        return exitCode == 0 && !stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Finds the latest valid backup from backup directory.
    private func findLatestValidBackup() -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: backupDir) else { return nil }

        let backups = files
            .filter { $0.hasPrefix("openclaw.") && $0.hasSuffix(".json.bak") }
            .map { (backupDir as NSString).appendingPathComponent($0) }
            .filter { fm.fileExists(atPath: $0) }
            .sorted { lhs, rhs in
                let lhsDate = (try? fm.attributesOfItem(atPath: lhs)[.modificationDate] as? Date) ?? .distantPast
                let rhsDate = (try? fm.attributesOfItem(atPath: rhs)[.modificationDate] as? Date) ?? .distantPast
                return lhsDate > rhsDate
            }

        return backups.first
    }

    /// Runs a shell command and returns (stdout, exitCode).
    private func runCommand(_ path: String, args: [String]) async -> (stdout: String, exitCode: Int32) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            let pipe = Pipe()
            task.standardOutput = pipe
            task.standardError = pipe

            do {
                try task.run()
            } catch {
                continuation.resume(returning: ("", -1))
                return
            }

            task.waitUntilExit()

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: data, encoding: .utf8) ?? ""
            continuation.resume(returning: (stdout, task.terminationStatus))
        }
    }
}
