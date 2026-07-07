import SwiftUI

struct RuntimeSelector: View {
    let selected: RuntimeScope
    let language: WidgetLanguage
    let onSelect: (RuntimeScope) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(RuntimeScope.allCases) { scope in
                Button {
                    onSelect(scope)
                } label: {
                    Text(label(for: scope))
                        .font(.system(size: 11, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .foregroundStyle(selected == scope ? .primary : .secondary)
                        .frame(minWidth: scope == .claudeCode ? 86 : 54, minHeight: 26)
                        .padding(.horizontal, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(selected == scope ? Color.primary.opacity(0.1) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .help(label(for: scope))
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(RuntimeViewPalette.controlFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.8)
                )
        )
    }

    private func label(for scope: RuntimeScope) -> String {
        switch scope {
        case .codex:
            return "Codex"
        case .claudeCode:
            return language.text("Claude Code", "Claude Code")
        }
    }
}

struct RuntimeStatusMenuView: View {
    @ObservedObject var store: UsageStore
    let openRuntime: (RuntimeScope) -> Void
    let openCurrent: () -> Void
    let quit: () -> Void

    @State private var language = WidgetLanguage.storedOrAutomatic()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            VStack(spacing: 8) {
                ForEach(RuntimeScope.allCases) { scope in
                    RuntimeSummaryCard(
                        summary: summary(for: scope),
                        isSelected: store.selectedRuntimeScope == scope,
                        language: language
                    ) {
                        openRuntime(scope)
                    }
                }
            }
            totalRow
            footer
        }
        .padding(14)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .scaledToFit()
                .frame(width: 24, height: 24)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("codexU")
                    .font(.system(size: 14, weight: .semibold))
                Text("\(language.text("刷新", "Refreshed")) \(runtimeTimeOnly(store.snapshot.refreshedAt))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                store.refresh()
            } label: {
                Image(systemName: store.isRefreshing ? "hourglass" : "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 24)
            }
            .buttonStyle(.plain)
            .help(language.text("刷新", "Refresh"))
        }
    }

    private var totalRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "sum")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(language.text("今日总 token", "Total tokens today"))
                .font(.system(size: 11, weight: .semibold))
            Spacer()
            Text(runtimeFormatTokens(store.totalTodayTokens))
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.primary.opacity(0.055))
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button {
                openCurrent()
            } label: {
                Label(language.text("打开主界面", "Open"), systemImage: "rectangle.on.rectangle")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
            Button {
                quit()
            } label: {
                Label(language.text("退出", "Quit"), systemImage: "power")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }

    private func summary(for scope: RuntimeScope) -> RuntimeMenuSummary {
        store.runtimeSnapshot(for: scope)?.summary ?? RuntimeMenuSummary(
            scope: scope,
            displayName: scope.displayName,
            status: .unavailable,
            fiveHourRemainingPercent: nil,
            fiveHourResetsAt: nil,
            sevenDayRemainingPercent: nil,
            sevenDayResetsAt: nil,
            todayTokens: nil,
            sourceLabel: language.text("等待本机统计", "Waiting for local records")
        )
    }
}

struct RuntimeSummaryCard: View {
    let summary: RuntimeMenuSummary
    let isSelected: Bool
    let language: WidgetLanguage
    let onOpen: () -> Void

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 8) {
                    Text(summary.displayName)
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text(summary.status.localized(language))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            Capsule(style: .continuous)
                                .fill(statusTint.opacity(0.16))
                        )
                        .foregroundStyle(statusTint)
                }

                HStack(spacing: 10) {
                    quotaColumn(
                        title: language.text("5小时剩余", "5h left"),
                        value: summary.fiveHourRemainingPercent,
                        resetsAt: summary.fiveHourResetsAt
                    )
                    quotaColumn(
                        title: language.text("7日剩余", "7d left"),
                        value: summary.sevenDayRemainingPercent,
                        resetsAt: summary.sevenDayResetsAt
                    )
                    VStack(alignment: .leading, spacing: 3) {
                        Text(language.text("今日 token", "Today"))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.secondary)
                        Text(runtimeFormatTokens(summary.todayTokens))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .monospacedDigit()
                    }
                    .frame(width: 82, alignment: .leading)
                }

                Text(localizedSourceLabel)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 102, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.045))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor.opacity(0.36) : Color.primary.opacity(0.08), lineWidth: 0.9)
                    )
            )
        }
        .buttonStyle(.plain)
        .help(language.text("打开 \(summary.displayName)", "Open \(summary.displayName)"))
    }

    private func quotaColumn(title: String, value: Double?, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(runtimeFormatPercent(value))
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .monospacedDigit()
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule(style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                    Capsule(style: .continuous)
                        .fill(statusTint.opacity(0.72))
                        .frame(width: proxy.size.width * CGFloat(max(0, min(100, value ?? 0)) / 100))
                }
            }
            .frame(height: 4)
            Text(resetsAt.map { runtimeTimeOnly($0) } ?? "--")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.tertiary)
        }
        .frame(width: 86, alignment: .leading)
    }

    private var statusTint: Color {
        switch summary.status {
        case .available:
            return RuntimeViewPalette.statusSuccess
        case .localOnly, .snapshotNeeded:
            return RuntimeViewPalette.statusWarning
        case .stale:
            return RuntimeViewPalette.statusInfo
        case .unavailable:
            return RuntimeViewPalette.statusDanger
        }
    }

    private var localizedSourceLabel: String {
        if language.isChinese {
            switch summary.scope {
            case .codex:
                return summary.fiveHourRemainingPercent == nil ? "本机统计；额度暂不可用" : "官方额度 + 本机统计"
            case .claudeCode:
                return summary.fiveHourRemainingPercent == nil ? "本机统计；额度需 active snapshot" : "active snapshot + 本机统计"
            }
        }
        switch summary.scope {
        case .codex:
            return summary.fiveHourRemainingPercent == nil ? "Local records; quota unavailable" : "Official quota + local records"
        case .claudeCode:
            return summary.fiveHourRemainingPercent == nil ? "Local records; quota needs active snapshot" : "Active snapshot + local records"
        }
    }
}

private func runtimeFormatTokens(_ value: Int64?) -> String {
    guard let value else { return "--" }
    let absValue = abs(Double(value))
    if absValue >= 1_000_000 {
        return String(format: "%.1fM", Double(value) / 1_000_000)
    }
    if absValue >= 1_000 {
        return String(format: "%.1fK", Double(value) / 1_000)
    }
    return "\(value)"
}

private func runtimeFormatPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    if value > 0, value < 1 {
        return "<1%"
    }
    return "\(Int(value.rounded()))%"
}

private func runtimeTimeOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter.string(from: date)
}

private enum RuntimeViewPalette {
    static let controlFill = Color.primary.opacity(0.045)
    static let statusSuccess = Color(red: 0.05, green: 0.55, blue: 0.32)
    static let statusWarning = Color(red: 0.72, green: 0.45, blue: 0.08)
    static let statusInfo = Color(red: 0.20, green: 0.38, blue: 0.76)
    static let statusDanger = Color(red: 0.78, green: 0.20, blue: 0.22)
}
