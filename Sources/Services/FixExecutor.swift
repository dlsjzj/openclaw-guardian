import Foundation

class FixExecutor {
    private let openclawBin = "/opt/homebrew/bin/openclaw"

    func fixGateway() async -> FixResult {
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

        return FixResult(
            action: "重启 Gateway (\(reason))",
            success: success,
            output: outputLines.joined(separator: "\n")
        )
    }
}
