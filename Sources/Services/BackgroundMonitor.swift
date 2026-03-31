import Foundation

struct RunningProcess: Identifiable {
    let id = UUID()
    let name: String
    let pid: Int
    let uptime: String
    let cpu: String
    let mem: String
}

class BackgroundMonitor: ObservableObject {
    @Published var processes: [RunningProcess] = []
    @Published var lastUpdate: Date = Date()

    private var timer: Timer?
    private let openclawBin = "/opt/homebrew/bin/openclaw"

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() {
        var list: [RunningProcess] = []

        // Gateway process
        let gatewayProc = getProcessInfo(pid: nil, nameHint: "openclaw-gateway")
        if let p = gatewayProc { list.append(p) }

        // Guardian itself
        if let p = getProcessInfo(pid: nil, nameHint: "openclaw-guardian") { list.append(p) }

        DispatchQueue.main.async {
            self.processes = list
            self.lastUpdate = Date()
        }
    }

    private func getProcessInfo(pid: Int32?, nameHint: String) -> RunningProcess? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-eo", "pid,comm,%cpu,%mem", "--no-headers"]

        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return nil }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else { return nil }

        for line in output.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            // Try match by name hint or PID
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count >= 4,
                  let pidNum = Int32(parts[0]) else { continue }

            let comm = String(parts[1])
            let cpu = String(parts[2])
            let mem = String(parts[3])

            let match = nameHint.isEmpty || comm.contains(nameHint)
            if !match { continue }

            let uptime = getUptime(pid: pidNum)
            return RunningProcess(name: comm, pid: Int(pidNum), uptime: uptime, cpu: cpu, mem: mem)
        }
        return nil
    }

    private func getUptime(pid: Int32) -> String {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = ["-o", "etime=", "-p", "\(pid)"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice

        do { try task.run() } catch { return "-" }
        task.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return "-"
        }

        return output.isEmpty ? "-" : output
    }
}
