import Foundation

enum HealthLevel {
    case healthy, unhealthy, unknown
}

struct HealthResult {
    let level: HealthLevel
    let modelsCount: Int           // loaded models from `openclaw models list`
    let configuredModelsCount: Int  // models declared in openclaw.json
    let hasConfigMismatch: Bool     // declared but not loaded = mismatch
    let rawOutput: String            // raw models list output
}

class HealthChecker {
    private let gatewayURL = "http://127.0.0.1:18789/health"
    private let configPath = NSHomeDirectory() + "/.openclaw/openclaw.json"

    // MARK: - Process alive check

    /// Checks if the gateway process is running (using lsof to check port 18789)
    func isProcessAlive() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        task.arguments = ["-i", ":18789"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return false }

        // lsof output contains "LISTEN" when port is in use
        return output.contains("LISTEN")
    }

    // MARK: - Basic health check (process alive)

    func check() async -> HealthLevel {
        guard let url = URL(string: gatewayURL) else { return .unknown }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 {
                if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let ok = json["ok"] as? Bool, ok {
                    return .healthy
                }
            }
            return .unhealthy
        } catch {
            return .unhealthy
        }
    }

    // MARK: - Model validation health check

    /// Checks both Gateway process health AND model configuration validity.
    /// Detects the critical case where models config is cleared but Gateway still runs.
    func checkWithModelValidation() async -> HealthResult {
        let processLevel = await check()

        // Run `openclaw models list` to get currently loaded models
        // Use `which openclaw` to find the actual path (may be /opt/homebrew/bin or /usr/local/bin)
        let openclawPath = findOpenClawBinary()
        let (rawOutput, _) = await runCommand(openclawPath, args: ["models", "list"])

        // Parse loaded model count from output
        // Output format:
        //   Model  Input  Ctx  Local  Auth  Tags
        //   minimax-portal/MiniMax-M2.7  text  200k  ...
        // We count lines that don't start with whitespace-first (skip header and blank lines)
        var loadedCount = 0
        let lines = rawOutput.components(separatedBy: "\n")
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            // Skip the table header line
            if trimmed.hasPrefix("Model ") { continue }
            // Count actual model entries (contain "/" and a provider)
            if trimmed.contains("/") && !trimmed.hasPrefix("[") {
                loadedCount += 1
            }
        }

        // Read openclaw.json and count configured model declarations
        let configuredCount = countConfiguredModels()

        // Determine mismatch:
        // - If configured > 0 but loaded == 0 → mismatch (models cleared but config still has them)
        // - If configured > 0 and loaded > 0 → healthy
        // - If configured == 0 and loaded == 0 → healthy (intentional empty config)
        let hasConfigMismatch = configuredCount > 0 && loadedCount == 0

        let level: HealthLevel
        if processLevel == .unhealthy || processLevel == .unknown {
            level = processLevel
        } else if hasConfigMismatch {
            level = .unhealthy
        } else {
            level = .healthy
        }

        return HealthResult(
            level: level,
            modelsCount: loadedCount,
            configuredModelsCount: configuredCount,
            hasConfigMismatch: hasConfigMismatch,
            rawOutput: rawOutput
        )
    }

    // MARK: - Private helpers

    /// Finds the actual openclaw binary path using `which openclaw`
    private func findOpenClawBinary() -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        task.arguments = ["openclaw"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else {
            return "/opt/homebrew/bin/openclaw"  // fallback default
        }
        return path
    }

    /// Counts total model entries across all providers AND agents.defaults.models in openclaw.json
    private func countConfiguredModels() -> Int {
        guard let data = FileManager.default.contents(atPath: configPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }

        var total = 0

        // Path 1: models.providers[].models[]
        if let modelsSection = json["models"] as? [String: Any],
           let providers = modelsSection["providers"] as? [String: [String: Any]] {
            for (_, provider) in providers {
                if let modelList = provider["models"] as? [[String: Any]] {
                    total += modelList.count
                }
            }
        }

        // Path 2: agents.defaults.models{} (e.g. { "minimax-portal/MiniMax-M2.7": {} })
        if let agentsSection = json["agents"] as? [String: Any],
           let defaults = agentsSection["defaults"] as? [String: Any],
           let models = defaults["models"] as? [String: Any] {
            total += models.count
        }

        return total
    }

    /// Runs a shell command and returns (stdout, exitCode)
    private func runCommand(_ path: String, args: [String]) async -> (String, Int32) {
        await withCheckedContinuation { continuation in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            task.standardOutput = stdoutPipe
            task.standardError = stderrPipe

            do {
                try task.run()
            } catch {
                continuation.resume(returning: ("", -1))
                return
            }

            task.waitUntilExit()

            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stdout = String(data: stdoutData, encoding: .utf8) ?? ""

            continuation.resume(returning: (stdout, task.terminationStatus))
        }
    }
}
