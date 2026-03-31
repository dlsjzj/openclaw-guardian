import SwiftUI

struct StatusBarView: View {
    @ObservedObject var monitorService: MonitorService
    @State private var selectedTab = 0
    @State private var checkResults: [CheckResult] = []
    @State private var isChecking = false

    private let selfChecker = SelfChecker()
    @StateObject private var backgroundMonitor = BackgroundMonitor()

    var body: some View {
        VStack(spacing: 0) {
            headerView
            Divider()
            statusCard
            Divider()
            VStack(spacing: 0) {
                // Custom tab bar
                HStack(spacing: 0) {
                    tabButton(title: "事件", icon: "list.bullet", tag: 0)
                    tabButton(title: "修复", icon: "wrench", tag: 1)
                    tabButton(title: "自检", icon: "checkmark.shield", tag: 2)
                    tabButton(title: "操作", icon: "gearshape", tag: 3)
                    tabButton(title: "后台", icon: "cpu", tag: 4)
                }
                .padding(.horizontal, 8)
                .padding(.top, 6)

                Divider()

                // Tab content
                Group {
                    switch selectedTab {
                    case 0: eventsTab
                    case 1: fixesTab
                    case 2: selfCheckTab
                    case 3: actionsTab
                    case 4: backgroundTab
                    default: eventsTab
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
            }
        }
        .frame(width: 380, height: 480)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Image(systemName: "shield.checkered")
                .font(.title2)
                .foregroundColor(.accentColor)
            Text("OpenClaw Guardian")
                .font(.headline)
            Spacer()
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(monitorService.status.displayName)
                .font(.subheadline)
                .foregroundColor(.secondary)
            Text(monitorService.isMonitoring ? "● 监控中" : "○ 已停止")
                .font(.caption)
                .foregroundColor(monitorService.isMonitoring ? .green : .gray)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Status Card

    private var statusCard: some View {
        HStack(spacing: 16) {
            statusItem(icon: "heart.fill", title: "Gateway", value: monitorService.status.displayName, color: statusColor)
            Divider().frame(height: 40)
            statusItem(icon: "clock", title: "运行时长", value: monitorService.gatewayUptime.isEmpty ? "—" : monitorService.gatewayUptime, color: .blue)
            Divider().frame(height: 40)
            statusItem(icon: "list.bullet", title: "事件数", value: "\(monitorService.recentEvents.count)", color: .purple)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 16)
    }

    private func statusItem(icon: String, title: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon).font(.caption).foregroundColor(color)
            Text(value).font(.system(.caption, design: .monospaced)).lineLimit(1)
            Text(title).font(.caption2).foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Events Tab

    private var eventsTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if monitorService.recentEvents.isEmpty {
                    emptyState("暂无日志事件")
                } else {
                    ForEach(monitorService.recentEvents.prefix(50)) { event in
                        eventRow(event)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func eventRow(_ event: LogEvent) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(event.formattedTime)
                .font(.system(.caption2, design: .monospaced))
                .foregroundColor(.secondary)
            Text(levelBadge(event.level))
                .font(.caption2)
                .padding(.horizontal, 4).padding(.vertical, 1)
                .background(levelColor(event.level).opacity(0.2))
                .foregroundColor(levelColor(event.level))
                .cornerRadius(3)
            Text(event.message).font(.caption).lineLimit(2)
        }
        .padding(.horizontal, 4).padding(.vertical, 2)
    }

    // MARK: - Fixes Tab

    private var fixesTab: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if monitorService.recentFixes.isEmpty {
                    emptyState("暂无修复记录")
                } else {
                    ForEach(monitorService.recentFixes.prefix(20)) { fix in
                        fixRow(fix)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func fixRow(_ fix: FixResult) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Image(systemName: fix.success ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.caption).foregroundColor(fix.success ? .green : .red)
                Text(fix.action).font(.caption).fontWeight(.medium)
                Spacer()
                Text(fix.formattedTime).font(.caption2).foregroundColor(.secondary)
            }
            if !fix.output.isEmpty {
                Text(fix.output).font(.caption2).foregroundColor(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 4).padding(.vertical, 4)
        .background(fix.success ? Color.green.opacity(0.05) : Color.red.opacity(0.05))
        .cornerRadius(4)
    }

    // MARK: - Self Check Tab

    private var selfCheckTab: some View {
        VStack(spacing: 8) {
            HStack {
                Text("自检报告")
                    .font(.headline)
                Spacer()
                Button(action: runSelfCheck) {
                    HStack(spacing: 4) {
                        if isChecking {
                            ProgressView()
                                .scaleEffect(0.6)
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                        Text(isChecking ? "检查中…" : "刷新")
                            .font(.caption)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.15))
                    .foregroundColor(.accentColor)
                    .cornerRadius(6)
                }
                .buttonStyle(.plain)
                .disabled(isChecking)
            }

            if checkResults.isEmpty && !isChecking {
                VStack(spacing: 12) {
                    Spacer()
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("点击「刷新」开始自检")
                        .font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(checkResults, id: \.name) { result in
                            checkResultRow(result)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }

            Spacer()
        }
        .padding(.top, 8)
        .onAppear {
            if checkResults.isEmpty {
                runSelfCheck()
            }
            backgroundMonitor.start()
        }
    }

    private func checkResultRow(_ result: CheckResult) -> some View {
        HStack(spacing: 8) {
            Image(systemName: result.status == .ok ? "checkmark.circle.fill" : (result.status == .warning ? "exclamationmark.circle.fill" : "xmark.circle.fill"))
                .font(.caption)
                .foregroundColor(result.status == .ok ? .green : (result.status == .warning ? .yellow : .red))

            VStack(alignment: .leading, spacing: 1) {
                Text(result.name)
                    .font(.caption)
                    .fontWeight(.medium)
                Text(result.message)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(6)
    }

    private func runSelfCheck() {
        isChecking = true
        DispatchQueue.global(qos: .userInitiated).async {
            let results = selfChecker.runAllChecks()
            DispatchQueue.main.async {
                self.checkResults = results
                self.isChecking = false
            }
        }
    }

    // MARK: - Actions Tab

    private var actionsTab: some View {
        VStack(spacing: 10) {
            Text("手动操作").font(.caption).foregroundColor(.secondary).frame(maxWidth: .infinity, alignment: .leading)

            actionButton(
                icon: "wrench.and.screwdriver.fill",
                title: "立即修复",
                subtitle: "重启 Gateway",
                color: .accentColor
            ) {
                monitorService.forceFixNow()
            }

            actionButton(
                icon: "trash",
                title: "清除历史",
                subtitle: "清空事件和修复记录",
                color: .red
            ) {
                monitorService.clearHistory()
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("自动监控").font(.caption).foregroundColor(.secondary)
                HStack {
                    Circle().fill(statusColor).frame(width: 8, height: 8)
                    Text(monitorService.status.displayName).font(.caption)
                    Spacer()
                    Text("每30秒检查一次").font(.caption2).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Spacer()
        }
        .padding(.top, 8)
    }

    private func actionButton(icon: String, title: String, subtitle: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Image(systemName: icon)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.caption).fontWeight(.medium)
                    Text(subtitle).font(.caption2).opacity(0.7)
                }
                Spacer()
                Image(systemName: "arrow.right.circle")
            }
            .padding(10)
            .background(color.opacity(0.12))
            .foregroundColor(color)
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    private func tabButton(title: String, icon: String, tag: Int) -> some View {
        Button(action: { selectedTab = tag }) {
            VStack(spacing: 2) {
                Image(systemName: icon)
                    .font(.caption)
                Text(title)
                    .font(.caption2)
            }
            .foregroundColor(selectedTab == tag ? .accentColor : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(
                selectedTab == tag
                    ? Color.accentColor.opacity(0.1)
                    : Color.clear
            )
            .cornerRadius(6)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundColor(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 20)
    }

    private var statusColor: Color {
        switch monitorService.status {
        case .healthy:  return .green
        case .warning:  return .yellow
        case .critical: return .red
        case .unknown:  return .gray
        }
    }

    private func levelColor(_ level: String) -> Color {
        switch level.uppercased() {
        case "ERROR", "FATAL", "CRITICAL": return .red
        case "WARN", "WARNING":            return .yellow
        case "INFO":                       return .blue
        default:                           return .gray
        }
    }

    private func levelBadge(_ level: String) -> String {
        switch level.uppercased() {
        case "ERROR", "FATAL", "CRITICAL": return level.uppercased()
        case "WARN", "WARNING":            return "WARN"
        case "INFO":                       return "INFO"
        default:                           return "LOG"
        }
    }

    private var backgroundTab: some View {
        ScrollView {
            VStack(spacing: 16) {
                // 主状态卡片
                aiStatusCard

                // 详细状态
                HStack(spacing: 12) {
                    detailPill(icon: "hammer.fill", label: "最后工具", value: backgroundMonitor.lastToolCallAt, color: .orange)
                    detailPill(icon: "checkmark.circle", label: "最后完成", value: backgroundMonitor.lastEndedAt, color: .green)
                }
                detailPill(icon: "arrow.right.circle", label: "最后新任务", value: backgroundMonitor.lastDispatchAt, color: .blue)

                Spacer()

                HStack {
                    Circle()
                        .fill(dotColor)
                        .frame(width: 8, height: 8)
                    Text("每 3 秒自动刷新")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(formatTime(backgroundMonitor.lastUpdate))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(12)
        }
    }

    private var aiStatusCard: some View {
        VStack(spacing: 12) {
            // 大图标 + 状态文字
            ZStack {
                Circle()
                    .fill(cardBgColor)
                    .frame(width: 80, height: 80)

                switch backgroundMonitor.activity {
                case .idle:
                    Image(systemName: "moon.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.gray)
                case .busy:
                    ProgressView()
                        .scaleEffect(1.5)
                        .frame(width: 40, height: 40)
                case .stuck:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 32))
                        .foregroundColor(.red)
                }
            }

            Text(activityLabel)
                .font(.title2)
                .fontWeight(.bold)
                .foregroundColor(activityTextColor)

            if backgroundMonitor.activity == .idle {
                Text("已空闲 \(backgroundMonitor.idleMinutes) 分钟")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else if backgroundMonitor.activity == .stuck {
                Text("超过 \(backgroundMonitor.idleMinutes) 分钟未响应")
                    .font(.subheadline)
                    .foregroundColor(.red)
            } else {
                Text("正在处理你的请求")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(cardBgColor.opacity(0.15))
        .cornerRadius(16)
    }

    private func detailPill(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.caption)
                    .foregroundColor(color)
                Text(label)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(.body, design: .monospaced))
                .fontWeight(.medium)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private var activityLabel: String {
        switch backgroundMonitor.activity {
        case .idle: return "空闲"
        case .busy: return "处理中"
        case .stuck: return "卡住了"
        }
    }

    private var dotColor: Color {
        switch backgroundMonitor.activity {
        case .idle: return .gray
        case .busy: return .green
        case .stuck: return .red
        }
    }

    private var cardBgColor: Color {
        switch backgroundMonitor.activity {
        case .idle: return .gray
        case .busy: return .green
        case .stuck: return .red
        }
    }

    private var activityTextColor: Color {
        switch backgroundMonitor.activity {
        case .idle: return .secondary
        case .busy: return .primary
        case .stuck: return .red
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
