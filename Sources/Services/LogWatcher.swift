import Foundation

class LogWatcher {
    private let logPath = "\(NSHomeDirectory())/.openclaw/logs/gateway.log"
    private var fileHandle: FileHandle?
    private var lastPosition: UInt64 = 0
    private var isRunning = false

    var onNewEvents: (([LogEvent]) -> Void)?

    // Regex patterns using NSRegularExpression for compatibility
    private let timestampPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "^(\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2})", options: [])
    }()
    private let levelPattern: NSRegularExpression? = {
        try? NSRegularExpression(pattern: "\\[(\\w+)\\]", options: [])
    }()

    init() {}

    func start() {
        guard !isRunning else { return }
        isRunning = true

        if !FileManager.default.fileExists(atPath: logPath) {
            startControlCenterWatching()
            return
        }

        guard let handle = FileHandle(forReadingAtPath: logPath) else {
            startControlCenterWatching()
            return
        }
        fileHandle = handle
        lastPosition = handle.seekToEndOfFile()

        // Read last 30 lines of existing content so events tab isn't empty on startup
        let existingEvents = readLastNLines(handle: handle, n: 30)
        if !existingEvents.isEmpty {
            onNewEvents?(existingEvents)
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: handle.fileDescriptor,
            eventMask: [.extend, .delete, .rename],
            queue: .global(qos: .utility)
        )

        source.setEventHandler { [weak self] in
            self?.readNewLines()
        }

        source.setCancelHandler {
            try? handle.close()
        }

        source.resume()
    }

    private func readLastNLines(handle: FileHandle, n: Int) -> [LogEvent] {
        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return [] }

        // Seek back ~10KB to capture enough lines
        let readStart = fileSize > 10000 ? fileSize - 10000 : 0
        handle.seek(toFileOffset: readStart)
        let data = handle.readData(ofLength: Int(fileSize - readStart))
        handle.seek(toFileOffset: fileSize)  // restore position

        guard let content = String(data: data, encoding: .utf8) else { return [] }
        let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
        let recentLines = Array(lines.suffix(n))
        return recentLines.compactMap { parseLine($0) }
    }

    func stop() {
        isRunning = false
        fileHandle?.closeFile()
        fileHandle = nil
    }

    private func readNewLines() {
        guard let handle = fileHandle else { return }

        let currentEnd = handle.seekToEndOfFile()
        if currentEnd > lastPosition {
            handle.seek(toFileOffset: lastPosition)
            let data = handle.readDataToEndOfFile()
            lastPosition = currentEnd

            if let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                let events = lines.compactMap { parseLine($0) }
                if !events.isEmpty {
                    onNewEvents?(events)
                }
            }
        }
    }

    private func parseLine(_ line: String) -> LogEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var timestamp = Date()
        var level = "INFO"
        var message = trimmed

        // Helper to convert NSRange to Range<String.Index>
        func stringRange(from nsRange: NSRange, in string: String) -> Range<String.Index>? {
            guard let range = Range(nsRange, in: string) else { return nil }
            return range
        }

        // Parse timestamp prefix
        if let tsMatch = timestampPattern?.firstMatch(in: trimmed, options: [], range: NSRange(trimmed.startIndex..., in: trimmed)),
           let tsRange = stringRange(from: tsMatch.range(at: 1), in: trimmed) {
            let tsString = String(trimmed[tsRange])
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let ts = formatter.date(from: tsString) {
                timestamp = ts
            } else {
                formatter.formatOptions = [.withInternetDateTime]
                if let ts = formatter.date(from: tsString) {
                    timestamp = ts
                }
            }
            if let afterRange = stringRange(from: tsMatch.range, in: trimmed) {
                let afterStart = trimmed.index(after: afterRange.upperBound)
                message = String(trimmed[afterStart...]).trimmingCharacters(in: .whitespaces)
            }
        }

        // Extract level from [LEVEL]
        if let lvMatch = levelPattern?.firstMatch(in: message, options: [], range: NSRange(message.startIndex..., in: message)),
           let lvRange = stringRange(from: lvMatch.range(at: 1), in: message) {
            level = String(message[lvRange])
            if let afterRange = stringRange(from: lvMatch.range, in: message) {
                let afterStart = message.index(after: afterRange.upperBound)
                message = String(message[afterStart...]).trimmingCharacters(in: .whitespaces)
            }
        }

        return LogEvent(timestamp: timestamp, level: level, message: message, rawLine: trimmed)
    }

    private func startControlCenterWatching() {
        let ccLogPaths = [
            "/tmp/openclaw-control-center/logs",
            "/tmp/openclaw-control-center/gateway.log"
        ]

        for path in ccLogPaths {
            if FileManager.default.fileExists(atPath: path) {
                lastPosition = 0
                Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
                    guard let self = self, self.isRunning else {
                        timer.invalidate()
                        return
                    }
                    self.pollFile(at: path)
                }
                return
            }
        }

        Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] timer in
            guard let self = self, self.isRunning else {
                timer.invalidate()
                return
            }
        }
    }

    private func pollFile(at path: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }

        let currentEnd = handle.seekToEndOfFile()
        if currentEnd > lastPosition {
            handle.seek(toFileOffset: lastPosition)
            let data = handle.readDataToEndOfFile()
            lastPosition = currentEnd

            if let content = String(data: data, encoding: .utf8) {
                let lines = content.components(separatedBy: "\n").filter { !$0.isEmpty }
                let events = lines.compactMap { parseLine($0) }
                if !events.isEmpty {
                    onNewEvents?(events)
                }
            }
        }
    }
}
