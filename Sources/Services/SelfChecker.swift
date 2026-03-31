import Foundation

struct CheckResult {
    let name: String
    let status: CheckStatus
    let message: String

    enum CheckStatus {
        case ok, warning, error, skipped
    }
}

class SelfChecker {
    // Files to check for integrity
    private let requiredMemoryFiles = [
        "soul.md",
        "identity.md",
        "user.md",
        "agents.md",
        "memory.md"
    ]

    private let workspacePath: String
    private let skillsPath: String

    init() {
        self.workspacePath = NSHomeDirectory() + "/.openclaw/workspace-zhongshu"
        self.skillsPath = NSHomeDirectory() + "/.openclaw/skills"
    }

    func runAllChecks() -> [CheckResult] {
        return [
            checkGateway(),
            checkDocker(),
            checkMemoryFiles(),
            checkSkillIntegrity(),
            checkCronJobs(),
            checkBackup()
        ]
    }

    private func checkGateway() -> CheckResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.arguments = ["-s", "--max-time", "3", "http://127.0.0.1:18789/health"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8),
              let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any],
              let ok = json["ok"] as? Bool, ok else {
            return CheckResult(name: "Gateway", status: .error, message: "无响应")
        }
        return CheckResult(name: "Gateway", status: .ok, message: "健康")
    }

    private func checkDocker() -> CheckResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/local/bin/docker")
        task.arguments = ["info"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        let exitCode = task.terminationStatus
        if exitCode == 0 {
            return CheckResult(name: "Docker", status: .ok, message: "正常运行")
        } else {
            return CheckResult(name: "Docker", status: .warning, message: "未安装/未运行")
        }
    }

    private func checkMemoryFiles() -> CheckResult {
        var missing: [String] = []
        for file in requiredMemoryFiles {
            let path = workspacePath + "/" + file
            if !FileManager.default.fileExists(atPath: path) {
                missing.append(file)
            }
        }
        if missing.isEmpty {
            return CheckResult(name: "记忆文件", status: .ok, message: "全部正常 (\(requiredMemoryFiles.count)个)")
        } else {
            return CheckResult(name: "记忆文件", status: .error, message: "缺失: \(missing.joined(separator: ", "))")
        }
    }

    private func checkSkillIntegrity() -> CheckResult {
        var issues: [String] = []
        let fileManager = FileManager.default

        guard let skills = try? fileManager.contentsOfDirectory(atPath: skillsPath) else {
            return CheckResult(name: "Skills", status: .warning, message: "无法读取 skills 目录")
        }

        for skill in skills where !skill.hasPrefix(".") {
            let skillPath = skillsPath + "/" + skill
            var isDir: ObjCBool = false
            guard fileManager.fileExists(atPath: skillPath, isDirectory: &isDir), isDir.boolValue else { continue }
            let skillMd = skillPath + "/SKILL.md"
            if !fileManager.fileExists(atPath: skillMd) {
                issues.append(skill + " (缺 SKILL.md)")
            }
        }

        if issues.isEmpty {
            let count = skills.filter { !$0.hasPrefix(".") }.count
            return CheckResult(name: "Skills", status: .ok, message: "全部正常 (\(count)个)")
        } else {
            return CheckResult(name: "Skills", status: .error, message: issues.joined(separator: "; "))
        }
    }

    private func checkCronJobs() -> CheckResult {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/crontab")
        task.arguments = ["-l"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard var content = String(data: data, encoding: .utf8) else {
            return CheckResult(name: "Cron", status: .warning, message: "无法读取")
        }
        // Remove comments
        content = content.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") && !$0.isEmpty }.joined()
        let jobCount = content.components(separatedBy: "\n").filter { !$0.isEmpty }.count
        if jobCount > 0 {
            return CheckResult(name: "Cron", status: .ok, message: "\(jobCount) 个任务")
        } else {
            return CheckResult(name: "Cron", status: .warning, message: "无任务")
        }
    }

    private func checkBackup() -> CheckResult {
        let backupDir = NSHomeDirectory() + "/.openclaw/backups"
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: backupDir) else {
            return CheckResult(name: "备份", status: .warning, message: "备份目录不存在")
        }
        guard let files = try? fileManager.contentsOfDirectory(atPath: backupDir) else {
            return CheckResult(name: "备份", status: .warning, message: "无法读取")
        }
        let bakFiles = files.filter { $0.hasSuffix(".bak") }
        if bakFiles.isEmpty {
            return CheckResult(name: "备份", status: .warning, message: "无备份文件")
        }
        let latest = bakFiles.sorted().last ?? "none"
        return CheckResult(name: "备份", status: .ok, message: "最新: \(latest)")
    }
}
