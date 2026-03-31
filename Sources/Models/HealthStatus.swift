import Foundation

enum HealthStatus: String, Equatable {
    case healthy  = "healthy"
    case warning = "warning"
    case critical = "critical"
    case unknown  = "unknown"

    var displayName: String {
        switch self {
        case .healthy:  return "运行正常"
        case .warning:  return "警告"
        case .critical: return "需修复"
        case .unknown:  return "未知"
        }
    }

    var iconName: String {
        switch self {
        case .healthy:  return "checkmark.shield.fill"
        case .warning:  return "exclamationmark.shield.fill"
        case .critical: return "xmark.shield.fill"
        case .unknown:  return "questionmark.circle"
        }
    }
}

struct LogEvent: Identifiable, Equatable {
    let id = UUID()
    let timestamp: Date
    let level: String
    let message: String
    let rawLine: String
    /// 智能错误分类
    var category: ErrorCategory = .normal

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}

struct FixResult: Identifiable {
    let id = UUID()
    let timestamp = Date()
    let action: String
    let success: Bool
    let output: String

    var formattedTime: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: timestamp)
    }
}
