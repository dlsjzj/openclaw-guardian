import Foundation

/// 限流记录结构
struct FixAttempt {
    let timestamp: Date
    let reason: String
    let success: Bool
}

class FixExecutor {
    private let openclawBin = "/opt/homebrew/bin/openclaw"
    
    // MARK: - 限流配置
    /// 每轮最大重启次数
    private let maxAttemptsPerRound = 3
    /// 两次重启之间的最小间隔（秒）
    private let minIntervalBetweenFixes: TimeInterval = 30
    /// 一轮限流窗口时长（秒），超过后重置计数
    private let rateLimitWindow: TimeInterval = 300  // 5分钟
    
    // MARK: - 限流状态
    private var fixHistory: [FixAttempt] = []
    private var lastFixTime: Date?
    private var isRateLimited: Bool = false
    
    /// 检查当前是否可以执行修复（限流检查）
    func canFix() -> (allowed: Bool, reason: String?) {
        let now = Date()
        
        // 清理过期的历史记录（超过窗口期的）
        cleanOldHistory(currentTime: now)
        
        // 检查是否处于全局限流状态
        if isRateLimited {
            // 检查是否可以解除限流
            if let lastFix = fixHistory.last,
               now.timeIntervalSince(lastFix.timestamp) >= rateLimitWindow {
                isRateLimited = false
                fixHistory.removeAll()
            } else {
                let remainingSeconds = Int(rateLimitWindow - (now.timeIntervalSince(fixHistory.last?.timestamp ?? now)))
                return (false, "已达重启上限（\(maxAttemptsPerRound)次），请等待 \(remainingSeconds/60) 分钟后重试")
            }
        }
        
        // 检查本轮回试次数
        let recentAttempts = fixHistory.filter { now.timeIntervalSince($0.timestamp) < rateLimitWindow }.count
        if recentAttempts >= maxAttemptsPerRound {
            isRateLimited = true
            return (false, "本轮已重启 \(maxAttemptsPerRound) 次，进入冷却期（5分钟）")
        }
        
        // 检查两次修复之间的最小间隔
        if let lastTime = lastFixTime,
           now.timeIntervalSince(lastTime) < minIntervalBetweenFixes {
            let waitSeconds = Int(minIntervalBetweenFixes - now.timeIntervalSince(lastTime))
            return (false, "请等待 \(waitSeconds) 秒后再试（防抖动）")
        }
        
        return (true, nil)
    }
    
    /// 获取当前限流状态信息
    func getRateLimitStatus() -> (attemptsUsed: Int, maxAttempts: Int, isLimited: Bool, nextAvailableIn: Int?) {
        cleanOldHistory(currentTime: Date())
        let recentAttempts = fixHistory.filter { Date().timeIntervalSince($0.timestamp) < rateLimitWindow }.count
        
        var nextAvailable: Int? = nil
        if isRateLimited, let lastFix = fixHistory.last {
            let elapsed = Date().timeIntervalSince(lastFix.timestamp)
            if elapsed < rateLimitWindow {
                nextAvailable = Int(rateLimitWindow - elapsed)
            }
        }
        
        return (recentAttempts, maxAttemptsPerRound, isRateLimited, nextAvailable)
    }

    func fixGateway() async -> FixResult {
        // 限流检查
        let check = canFix()
        if !check.allowed {
            return FixResult(
                action: "修复被拒绝",
                success: false,
                output: "限流原因: \(check.reason ?? "未知")"
            )
        }
        
        // 记录修复尝试
        // Step 1: Check if gateway process is running
        let isRunning = checkGatewayRunning()
        if !isRunning {
            return await restartGateway(reason: "gateway not running")
        }

        // Step 2: Try health check first
        let healthChecker = HealthChecker()
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

    private func restartGateway(reason: String) async -> FixResult {
        var outputLines: [String] = []
        outputLines.append("原因: \(reason)")

        // Restart gateway
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

        // Wait and check health
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        let healthChecker = HealthChecker()
        let newLevel = await healthChecker.check()

        let success = newLevel == .healthy
        outputLines.append("重启后状态: \(newLevel)")

        // 记录本次尝试
        let attempt = FixAttempt(
            timestamp: Date(),
            reason: reason,
            success: success
        )
        fixHistory.append(attempt)
        
        // 如果连续失败达到上限，触发限流
        let recentFailures = fixHistory
            .filter { Date().timeIntervalSince($0.timestamp) < rateLimitWindow }
            .filter { !$0.success }
            .count
        if recentFailures >= maxAttemptsPerRound {
            isRateLimited = true
            outputLines.append("⚠️ 已连续失败 \(maxAttemptsPerRound) 次，进入冷却期（5分钟）")
        }
        
        return FixResult(
            action: "重启 Gateway (\(reason))",
            success: success,
            output: outputLines.joined(separator: "\n")
        )
    }
    
    // MARK: - Private Helpers
    
    private func cleanOldHistory(currentTime: Date) {
        fixHistory.removeAll { currentTime.timeIntervalSince($0.timestamp) >= rateLimitWindow }
    }
}
