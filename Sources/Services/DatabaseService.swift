import Foundation
import SQLite

/// SQLite-backed persistence service for audit logging.
/// Records health checks, heal events, and system events with 7-day retention.
class DatabaseService {
    static let shared = DatabaseService()

    private var db: Connection?

    // Schema: health_checks
    private let healthChecks = Table("health_checks")
    private let hcId = SQLite.Expression<Int64>("id")
    private let hcTimestamp = SQLite.Expression<Date>("timestamp")
    private let hcStatus = SQLite.Expression<String>("status")
    private let hcResponseTimeMs = SQLite.Expression<Int>("response_time_ms")
    private let hcCpuUsage = SQLite.Expression<Double>("cpu_usage")
    private let hcMemUsage = SQLite.Expression<Double>("mem_usage")
    private let hcErrorMsg = SQLite.Expression<String?>("error_msg")

    // Schema: heal_events
    private let healEvents = Table("heal_events")
    private let heId = SQLite.Expression<Int64>("id")
    private let heTimestamp = SQLite.Expression<Date>("timestamp")
    private let heReason = SQLite.Expression<String>("reason")
    private let heMethod = SQLite.Expression<String>("method")
    private let heResult = SQLite.Expression<String>("result")
    private let heReportPath = SQLite.Expression<String?>("report_path")

    // Schema: system_events
    private let systemEvents = Table("system_events")
    private let seId = SQLite.Expression<Int64>("id")
    private let seTimestamp = SQLite.Expression<Date>("timestamp")
    private let seEventType = SQLite.Expression<String>("event_type")
    private let seMessage = SQLite.Expression<String>("message")

    // Schema: diagnosis_events (self-healing audit trail)
    private let diagnosisEvents = Table("diagnosis_events")
    private let deId = SQLite.Expression<Int64>("id")
    private let deTimestamp = SQLite.Expression<Date>("timestamp")
    private let deCategory = SQLite.Expression<String>("category")
    private let deCause = SQLite.Expression<String>("cause")
    private let deConfidence = SQLite.Expression<Double>("confidence")
    private let deFixAction = SQLite.Expression<String>("fix_action")
    private let deFixSuccess = SQLite.Expression<Bool>("fix_success")
    private let deFixVerified = SQLite.Expression<Bool>("fix_verified")
    private let deFixOutput = SQLite.Expression<String?>("fix_output")

    private init() {
        setupDatabase()
    }

    private func setupDatabase() {
        do {
            let dbDir = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!)
                .appendingPathComponent("openclaw-guardian", isDirectory: true)

            try FileManager.default.createDirectory(at: dbDir, withIntermediateDirectories: true)

            let dbPath = dbDir.appendingPathComponent("guardian.sqlite").path
            db = try Connection(dbPath)

            try createTables()
        } catch {
            print("[Database] Setup failed: \(error)")
        }
    }

    private func createTables() throws {
        guard let db = db else { return }

        try db.run(healthChecks.create(ifNotExists: true) { t in
            t.column(hcId, primaryKey: .autoincrement)
            t.column(hcTimestamp)
            t.column(hcStatus)
            t.column(hcResponseTimeMs)
            t.column(hcCpuUsage)
            t.column(hcMemUsage)
            t.column(hcErrorMsg)
        })

        try db.run(healEvents.create(ifNotExists: true) { t in
            t.column(heId, primaryKey: .autoincrement)
            t.column(heTimestamp)
            t.column(heReason)
            t.column(heMethod)
            t.column(heResult)
            t.column(heReportPath)
        })

        try db.run(systemEvents.create(ifNotExists: true) { t in
            t.column(seId, primaryKey: .autoincrement)
            t.column(seTimestamp)
            t.column(seEventType)
            t.column(seMessage)
        })

        try db.run(diagnosisEvents.create(ifNotExists: true) { t in
            t.column(deId, primaryKey: .autoincrement)
            t.column(deTimestamp)
            t.column(deCategory)
            t.column(deCause)
            t.column(deConfidence)
            t.column(deFixAction)
            t.column(deFixSuccess)
            t.column(deFixVerified)
            t.column(deFixOutput)
        })

        // Retention index
        try db.run(healthChecks.createIndex(hcTimestamp, ifNotExists: true))
        try db.run(healEvents.createIndex(heTimestamp, ifNotExists: true))
        try db.run(systemEvents.createIndex(seTimestamp, ifNotExists: true))
        try db.run(diagnosisEvents.createIndex(deTimestamp, ifNotExists: true))
    }

    // MARK: - Public API

    func recordHealthCheck(
        status: String,
        responseTimeMs: Int,
        cpuUsage: Double,
        memUsage: Double,
        errorMsg: String
    ) {
        guard let db = db else { return }
        do {
            try db.run(healthChecks.insert(
                hcTimestamp <- Date(),
                hcStatus <- status,
                hcResponseTimeMs <- responseTimeMs,
                hcCpuUsage <- cpuUsage,
                hcMemUsage <- memUsage,
                hcErrorMsg <- (errorMsg.isEmpty ? nil : errorMsg)
            ))
        } catch {
            print("[Database] recordHealthCheck failed: \(error)")
        }
    }

    func recordHealEvent(
        reason: String,
        method: String,
        result: String,
        reportPath: String?
    ) {
        guard let db = db else { return }
        do {
            try db.run(healEvents.insert(
                heTimestamp <- Date(),
                heReason <- reason,
                heMethod <- method,
                heResult <- result,
                heReportPath <- reportPath
            ))
        } catch {
            print("[Database] recordHealEvent failed: \(error)")
        }
    }

    func recordSystemEvent(eventType: String, message: String) {
        guard let db = db else { return }
        do {
            try db.run(systemEvents.insert(
                seTimestamp <- Date(),
                seEventType <- eventType,
                seMessage <- message
            ))
        } catch {
            print("[Database] recordSystemEvent failed: \(error)")
        }
    }

    /// Records a full diagnosis → fix cycle for the self-healing audit trail.
    func recordDiagnosisEvent(diagnosis: DiagnosisResult, fixResult: DiagnosisFixResult) {
        guard let db = db else { return }
        do {
            try db.run(diagnosisEvents.insert(
                deTimestamp <- diagnosis.diagnosedAt,
                deCategory <- diagnosis.category.rawValue,
                deCause <- diagnosis.cause,
                deConfidence <- diagnosis.confidence,
                deFixAction <- diagnosis.fixAction.description,
                deFixSuccess <- fixResult.success,
                deFixVerified <- fixResult.verified,
                deFixOutput <- fixResult.output.isEmpty ? nil : fixResult.output
            ))
        } catch {
            print("[Database] recordDiagnosisEvent failed: \(error)")
        }
    }

    /// Cleans up records older than `days` days.
    func cleanupOldData(days: Int = 7) {
        guard let db = db else { return }
        let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
        do {
            try db.run(healthChecks.filter(hcTimestamp < cutoff).delete())
            try db.run(healEvents.filter(heTimestamp < cutoff).delete())
            try db.run(systemEvents.filter(seTimestamp < cutoff).delete())
            print("[Database] Cleanup done, removed records before \(cutoff)")
        } catch {
            print("[Database] cleanupOldData failed: \(error)")
        }
    }

    /// Returns recent heal events for display (last `limit` rows).
    func recentHealEvents(limit: Int = 20) -> [(id: Int64, timestamp: Date, reason: String, method: String, result: String)] {
        guard let db = db else { return [] }
        var rows: [(Int64, Date, String, String, String)] = []
        do {
            let query = healEvents.order(heTimestamp.desc).limit(limit)
            for row in try db.prepare(query) {
                rows.append((row[heId], row[heTimestamp], row[heReason], row[heMethod], row[heResult]))
            }
        } catch {
            print("[Database] recentHealEvents failed: \(error)")
        }
        return rows
    }
}
