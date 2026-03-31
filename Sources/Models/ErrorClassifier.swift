import Foundation

/// 错误分类结果
enum ErrorCategory: String {
    /// Gateway 核心崩溃 — 需要重启
    case gatewayCrash = "Gateway崩溃"
    /// Gateway 健康检查失败 — 可能需要重启
    case gatewayUnhealthy = "Gateway异常"
    /// 模型 API 认证失败 — 不应重启，需人工检查配置
    case authError = "认证失败"
    /// 模型 API 限流 — 不应重启，等待自动恢复
    case rateLimit = "限流"
    /// 模型 API 过载 — 不应重启，等待自动恢复
    case overloaded = "过载"
    /// 插件级错误（embedding/summarize 失败等）— 不应重启
    case pluginError = "插件错误"
    /// 网络错误（fetch failed）— 可能是暂时的
    case networkError = "网络错误"
    /// 非致命警告（超时、重连等）
    case warning = "警告"
    /// 普通日志
    case normal = "正常"

    /// 该分类是否应触发 Gateway 重启
    var shouldRestart: Bool {
        switch self {
        case .gatewayCrash, .gatewayUnhealthy:
            return true
        default:
            return false
        }
    }

    /// 该分类对应的 HealthStatus
    var healthStatus: HealthStatus? {
        switch self {
        case .gatewayCrash:
            return .critical
        case .gatewayUnhealthy:
            return .critical
        case .authError, .overloaded, .pluginError, .networkError:
            return .warning
        case .rateLimit:
            return .warning
        case .warning:
            return .warning
        default:
            return nil
        }
    }

    /// 分类对应的 UI 颜色
    var uiColor: String {
        switch self {
        case .gatewayCrash:   return "red"
        case .gatewayUnhealthy: return "red"
        case .authError:      return "orange"
        case .rateLimit:      return "yellow"
        case .overloaded:     return "yellow"
        case .pluginError:    return "orange"
        case .networkError:   return "orange"
        case .warning:        return "yellow"
        case .normal:         return "gray"
        }
    }
}

/// 从日志行智能分类错误
struct ErrorClassifier {

    /// Gateway 崩溃相关关键词（需要重启）
    private static let gatewayCrashPatterns = [
        "oom", "out of memory", "killed",
        "panic", "segfault", "crash",
        "unhandled rejection",
        "fatal error",
        "listen eaddrnotavail",
        "port already in use",
        "eaddrinuse",
        "Gateway startup timed out",
        "Process.*exited"
    ]

    /// 认证失败关键词（不应重启）
    private static let authPatterns = [
        "401", "authentication_error", "unauthorized",
        "login fail", "api key", "invalid key",
        "Please carry the API secret key"
    ]

    /// 限流关键词（不应重启）
    private static let rateLimitPatterns = [
        "429", "rate.limit", "rate_limited",
        "too many requests", "request limit",
        "quota exceeded", "throttl"
    ]

    /// 过载关键词（不应重启）
    private static let overloadedPatterns = [
        "529", "overloaded", "overload_error",
        "负载较高", "服务集群负载",
        "temporarily overloaded", "请稍后重试"
    ]

    /// 网络错误关键词
    private static let networkPatterns = [
        "TypeError: fetch failed",
        "ECONNREFUSED", "ECONNRESET",
        "ENOTFOUND", "ETIMEDOUT",
        "network error", "socket hang up"
    ]

    /// 插件错误关键词（不应重启）
    private static let pluginPatterns = [
        "summarize failed", "summarize fallback",
        "judgeNewTopic failed",
        "filterRelevant failed",
        "Embedding failed",
        "plugin tool name conflict",
        "Vector search failed",
        "Skill vector search failed",
        "[plugins]"
    ]

    /// 纯噪音关键词（完全不显示）
    static let noisePatterns = [
        "tool call: exec", "tool done: exec",
        "dispatching to agent",
        "\\[36m", "auto-recall",
        "Telemetry flush",
        "Loading local embedding",
        "gateway restart",
        "session history",
        "missing tool result",
        "synthetic error",
        "auto-recall-skill",
        "prependContext"
    ]

    /// 分类一条日志消息
    static func classify(_ message: String) -> ErrorCategory {
        let lower = message.lowercased()

        // 1. Gateway 崩溃（最高优先级）
        for pattern in gatewayCrashPatterns {
            if lower.contains(pattern.lowercased()) {
                return .gatewayCrash
            }
        }

        // 2. 认证失败
        for pattern in authPatterns {
            if lower.contains(pattern.lowercased()) {
                return .authError
            }
        }

        // 3. 限流
        for pattern in rateLimitPatterns {
            if lower.contains(pattern.lowercased()) {
                return .rateLimit
            }
        }

        // 4. 过载
        for pattern in overloadedPatterns {
            if lower.contains(pattern.lowercased()) {
                return .overloaded
            }
        }

        // 5. 网络错误
        for pattern in networkPatterns {
            if lower.contains(pattern.lowercased()) {
                return .networkError
            }
        }

        // 6. 插件错误
        for pattern in pluginPatterns {
            if lower.contains(pattern.lowercased()) {
                return .pluginError
            }
        }

        // 7. 普通警告
        let warnPatterns = ["timeout", "slow query", "retry", "reconnecting", "warn"]
        for pattern in warnPatterns {
            if lower.contains(pattern.lowercased()) {
                return .warning
            }
        }

        return .normal
    }

    /// 判断是否为噪音日志
    static func isNoise(_ message: String) -> Bool {
        for pattern in noisePatterns {
            if message.contains(pattern) {
                return true
            }
        }
        return false
    }
}

/// API 错误统计
struct APIErrorStats: Equatable {
    var authErrors: Int = 0
    var rateLimitErrors: Int = 0
    var overloadedErrors: Int = 0
    var pluginErrors: Int = 0
    var networkErrors: Int = 0
    var gatewayErrors: Int = 0

    var total: Int {
        authErrors + rateLimitErrors + overloadedErrors + pluginErrors + networkErrors + gatewayErrors
    }

    var hasCriticalErrors: Bool {
        gatewayErrors > 0
    }

    var hasWarningErrors: Bool {
        authErrors > 0 || rateLimitErrors > 0 || overloadedErrors > 0 || pluginErrors > 0 || networkErrors > 0
    }

    mutating func record(_ category: ErrorCategory) {
        switch category {
        case .gatewayCrash, .gatewayUnhealthy:
            gatewayErrors += 1
        case .authError:
            authErrors += 1
        case .rateLimit:
            rateLimitErrors += 1
        case .overloaded:
            overloadedErrors += 1
        case .pluginError:
            pluginErrors += 1
        case .networkError:
            networkErrors += 1
        default:
            break
        }
    }

    mutating func reset() {
        self = APIErrorStats()
    }
}
