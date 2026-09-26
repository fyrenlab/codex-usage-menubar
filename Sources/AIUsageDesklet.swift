import AppKit
import CoreGraphics
import Darwin
import Foundation
import SwiftUI
import WidgetKit

#if !TESTING
@main
struct AIUsageDeskletApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
#endif

enum MenuBarLimitDisplay: String {
    case weekly
    case fiveHour
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var statusSummaryMenuItem: NSMenuItem?
    private var weeklyDisplayMenuItem: NSMenuItem?
    private var fiveHourDisplayMenuItem: NSMenuItem?
    private var lastFastSyncDate: Date?
    private var lastPersistedFastUsageKey: String?
    private var sessionChangeMonitor: CodexSessionChangeMonitor?
    private var authoritativeRefreshTimer: Timer?
    private var fullRefreshTimer: Timer?
    private var isFastRefreshRunning = false
    private var fastRefreshPending = false
    private var isAuthoritativeRefreshRunning = false
    private var latestAppliedLimitStatus: CodexFastLimitStatus?
    private var isFullRefreshRunning = false
    private let authoritativeRefreshInterval: TimeInterval = 5 * 60
    private let fullRefreshInterval: TimeInterval = 6 * 60 * 60
    private let launchFullRefreshFreshAge: TimeInterval = 6 * 60 * 60

    func applicationDidFinishLaunching(_ notification: Notification) {
        seedDefaultsIfNeeded()
        setupMenuBarItem()
        refreshFastMenuBarLimit()
        refreshAuthoritativeRateLimits()

        let monitor = CodexSessionChangeMonitor { [weak self] in
            DispatchQueue.main.async {
                self?.refreshFastMenuBarLimit()
            }
        }
        sessionChangeMonitor = monitor
        monitor.start()

        authoritativeRefreshTimer = Timer.scheduledTimer(
            withTimeInterval: authoritativeRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            self?.refreshAuthoritativeRateLimits()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sessionChangeMonitor?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    @objc private func openDetailWindow() {
        if window == nil {
            window = makeDetailWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func refreshNowFromMenu() {
        refreshFastMenuBarLimit()
        refreshAuthoritativeRateLimits()
    }

    @objc private func selectWeeklyDisplay() {
        UserDefaults.standard.set(MenuBarLimitDisplay.weekly.rawValue, forKey: "menuBarLimitDisplay")
        renderMenuBar()
    }

    @objc private func selectFiveHourDisplay() {
        UserDefaults.standard.set(MenuBarLimitDisplay.fiveHour.rawValue, forKey: "menuBarLimitDisplay")
        renderMenuBar()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func makeDetailWindow() -> NSWindow {
        let contentView = UsageWidgetView()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 630),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )

        window.title = "Codex计费"
        window.titleVisibility = .visible
        window.titlebarAppearsTransparent = false
        window.isOpaque = true
        window.backgroundColor = NSColor.windowBackgroundColor
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.level = .normal
        return window
    }

    private func setupMenuBarItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.title = "7d余--"
        item.button?.toolTip = "Codex 7天余量"

        let menu = NSMenu()
        let summaryItem = NSMenuItem(title: "7d可用 -- · 刷新 --:-- · 同步 --:--:--", action: nil, keyEquivalent: "")
        summaryItem.isEnabled = false
        menu.addItem(summaryItem)
        menu.addItem(.separator())

        let displayItem = NSMenuItem(title: "菜单栏显示", action: nil, keyEquivalent: "")
        let displayMenu = NSMenu()
        let weeklyItem = NSMenuItem(title: "7d余量", action: #selector(selectWeeklyDisplay), keyEquivalent: "")
        weeklyItem.target = self
        displayMenu.addItem(weeklyItem)
        let fiveHourItem = NSMenuItem(title: "5小时余量", action: #selector(selectFiveHourDisplay), keyEquivalent: "")
        fiveHourItem.target = self
        displayMenu.addItem(fiveHourItem)
        displayItem.submenu = displayMenu
        menu.addItem(displayItem)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: "打开详情", action: #selector(openDetailWindow), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "立即刷新", action: #selector(refreshNowFromMenu), keyEquivalent: "r"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
        item.menu = menu

        statusSummaryMenuItem = summaryItem
        weeklyDisplayMenuItem = weeklyItem
        fiveHourDisplayMenuItem = fiveHourItem
        statusItem = item
        let savedSyncDate = UserDefaults.standard.string(forKey: "lastSyncISO").flatMap(isoFormatter.date(from:))
        lastFastSyncDate = savedSyncDate
        renderMenuBar()
    }

    private func refreshFastMenuBarLimit() {
        guard !isFastRefreshRunning else {
            fastRefreshPending = true
            return
        }
        isFastRefreshRunning = true

        Task {
            let result = await Task.detached(priority: .background) {
                Result { try CodexFastLimitReader.loadLatestFiveHourLimitStatus() }
            }.value

            await MainActor.run {
                isFastRefreshRunning = false
                switch result {
                case let .success(status):
                    applyLimitStatus(status)
                case .failure:
                    renderMenuBar()
                }

                if fastRefreshPending {
                    fastRefreshPending = false
                    refreshFastMenuBarLimit()
                }
            }
        }
    }

    private func refreshAuthoritativeRateLimits() {
        guard !isAuthoritativeRefreshRunning else { return }
        isAuthoritativeRefreshRunning = true

        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try CodexRPCUsageReader.loadCurrentLimitStatus() }
            }.value

            await MainActor.run {
                isAuthoritativeRefreshRunning = false
                if case let .success(status) = result {
                    applyLimitStatus(status)
                }
            }
        }
    }

    private func applyLimitStatus(_ status: CodexFastLimitStatus) {
        var resolvedStatus = status
        if let current = latestAppliedLimitStatus, !status.isAuthoritative {
            guard status.eventDate >= current.eventDate else { return }

            let primaryWindowMatches = current.primaryWindowMinutes == status.primaryWindowMinutes
                && sameLimitWindow(current.resetsAt, status.resetsAt)
            let primaryUsed = primaryWindowMatches
                ? max(current.usedPercent, status.usedPercent)
                : status.usedPercent
            let secondaryUsed: Double?
            let secondaryWindowMatches = current.secondaryWindowMinutes == status.secondaryWindowMinutes
                && sameLimitWindow(current.secondaryResetsAt, status.secondaryResetsAt)
            if secondaryWindowMatches {
                switch (current.secondaryUsedPercent, status.secondaryUsedPercent) {
                case let (.some(currentValue), .some(newValue)):
                    secondaryUsed = max(currentValue, newValue)
                case let (.some(currentValue), .none):
                    secondaryUsed = currentValue
                case let (.none, .some(newValue)):
                    secondaryUsed = newValue
                case (.none, .none):
                    secondaryUsed = nil
                }
            } else {
                secondaryUsed = status.secondaryUsedPercent
            }

            resolvedStatus = CodexFastLimitStatus(
                usedPercent: primaryUsed,
                secondaryUsedPercent: secondaryUsed,
                resetsAt: status.resetsAt,
                secondaryResetsAt: status.secondaryResetsAt,
                primaryWindowMinutes: status.primaryWindowMinutes,
                secondaryWindowMinutes: status.secondaryWindowMinutes,
                eventDate: status.eventDate,
                isMainCodexLimit: status.isMainCodexLimit,
                isAuthoritative: false
            )
        }
        latestAppliedLimitStatus = resolvedStatus
        lastFastSyncDate = resolvedStatus.eventDate
        renderMenuBar()
        persistFastLimitStatus(resolvedStatus)
    }

    private func sameLimitWindow(_ lhs: Date?, _ rhs: Date?) -> Bool {
        guard let lhs, let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) <= 5
    }

    private func refreshFullUsageInBackground(force: Bool = false) {
        guard force || shouldRunFullUsageRefresh(maxAge: fullRefreshInterval) else { return }
        guard !isFullRefreshRunning else { return }
        isFullRefreshRunning = true

        Task {
            let result = await Task.detached(priority: .background) {
                Result { try CodexLogUsageReader.load() }
            }.value

            await MainActor.run {
                isFullRefreshRunning = false
                switch result {
                case let .success(usage):
                    applyMenuBarUsage(usage)
                case .failure:
                    renderMenuBar()
                }
            }
        }
    }

    private func shouldRunFullUsageRefresh(maxAge: TimeInterval) -> Bool {
        guard
            let lastSyncISO = UserDefaults.standard.string(forKey: "lastSyncISO"),
            !lastSyncISO.isEmpty,
            let lastSyncDate = isoFormatter.date(from: lastSyncISO)
        else {
            return true
        }
        return Date().timeIntervalSince(lastSyncDate) > maxAge
    }

    private func persistFastLimitStatus(_ status: CodexFastLimitStatus) {
        let fiveHourWindow = status.window(minutes: 300)
        let weeklyWindow = status.window(minutes: 10_080)
        let fiveHourUsedPercent = fiveHourWindow.map { max(0, min(100, $0.usedPercent)) }
        let sevenDayAvailablePercent = weeklyWindow.map { max(0, min(100, 100 - $0.usedPercent)) }
        let fiveHourResetMinute = fiveHourWindow?.resetsAt.map { Int($0.timeIntervalSince1970 / 60) } ?? -1
        let weeklyResetMinute = weeklyWindow?.resetsAt.map { Int($0.timeIntervalSince1970 / 60) } ?? -1
        let fiveHourKey = fiveHourUsedPercent.map { Int($0.rounded()) } ?? -1
        let sevenDayKey = sevenDayAvailablePercent.map { Int($0.rounded()) } ?? -1
        let eventSecond = Int(status.eventDate.timeIntervalSince1970)
        let key = "\(fiveHourKey)|\(sevenDayKey)|\(fiveHourResetMinute)|\(weeklyResetMinute)|\(eventSecond)"
        guard key != lastPersistedFastUsageKey else { return }
        lastPersistedFastUsageKey = key

        let defaults = UserDefaults.standard
        let syncISO = isoFormatter.string(from: status.eventDate)
        defaults.set(fiveHourUsedPercent ?? -1, forKey: "fiveHourUsagePercent")
        defaults.set(sevenDayAvailablePercent ?? -1, forKey: "sevenDayAvailablePercent")
        defaults.set("Codex 日志", forKey: "dataMode")
        defaults.set(syncISO, forKey: "lastSyncISO")

        let renewalDate = defaults.string(forKey: "renewalDate") ?? ""
        let theme = defaults.string(forKey: "theme") ?? "graphite"
        writeSharedSnapshot(
            SharedUsageSnapshot(
                dataMode: "Codex 日志",
                renewalDate: renewalDate,
                todayInput: defaults.integer(forKey: "todayInput"),
                todayOutput: defaults.integer(forKey: "todayOutput"),
                todayCache: defaults.integer(forKey: "todayCache"),
                fiveHourUsed: defaults.integer(forKey: "fiveHourUsed"),
                fiveHourUsagePercent: fiveHourUsedPercent ?? -1,
                sevenDayAvailablePercent: sevenDayAvailablePercent ?? -1,
                dailyTokens: defaults.string(forKey: "dailyTokens") ?? "",
                lastSyncISO: syncISO,
                fetchError: "",
                theme: theme
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func applyMenuBarUsage(_ usage: CodexLocalUsage) {
        let defaults = UserDefaults.standard
        let renewalDate = defaults.string(forKey: "renewalDate") ?? ""
        let theme = defaults.string(forKey: "theme") ?? "graphite"
        defaults.set("Codex 日志", forKey: "dataMode")
        defaults.set(usage.todayInput, forKey: "todayInput")
        defaults.set(usage.todayOutput, forKey: "todayOutput")
        defaults.set(usage.todayCached, forKey: "todayCache")
        defaults.set(usage.fiveHourTokens, forKey: "fiveHourUsed")
        defaults.set(usage.fiveHourUsagePercent ?? -1, forKey: "fiveHourUsagePercent")
        defaults.set(usage.sevenDayAvailablePercent ?? -1, forKey: "sevenDayAvailablePercent")
        defaults.set(usage.dailyTotals.map(String.init).joined(separator: "\n"), forKey: "dailyTokens")
        defaults.set(isoFormatter.string(from: Date()), forKey: "lastSyncISO")
        defaults.set("", forKey: "fetchError")

        writeSharedSnapshot(
            SharedUsageSnapshot(
                dataMode: "Codex 日志",
                renewalDate: renewalDate,
                todayInput: usage.todayInput,
                todayOutput: usage.todayOutput,
                todayCache: usage.todayCached,
                fiveHourUsed: usage.fiveHourTokens,
                fiveHourUsagePercent: usage.fiveHourUsagePercent ?? -1,
                sevenDayAvailablePercent: usage.sevenDayAvailablePercent ?? -1,
                dailyTokens: usage.dailyTotals.map(String.init).joined(separator: "\n"),
                lastSyncISO: isoFormatter.string(from: Date()),
                fetchError: "",
                theme: theme
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
        renderMenuBar()
    }

    private func renderMenuBar() {
        let defaults = UserDefaults.standard
        let preferredMode = MenuBarLimitDisplay(
            rawValue: defaults.string(forKey: "menuBarLimitDisplay") ?? ""
        ) ?? .weekly
        let weeklyWindow = latestAppliedLimitStatus?.window(minutes: 10_080)
        let fiveHourWindow = latestAppliedLimitStatus?.window(minutes: 300)
        let availabilityIsKnown = latestAppliedLimitStatus != nil
        let weeklyAvailable = !availabilityIsKnown || weeklyWindow != nil
        let fiveHourAvailable = !availabilityIsKnown || fiveHourWindow != nil
        let mode = resolvedMenuBarLimitDisplay(
            preferred: preferredMode,
            weeklyAvailable: weeklyAvailable,
            fiveHourAvailable: fiveHourAvailable
        )
        if mode != preferredMode {
            defaults.set(mode.rawValue, forKey: "menuBarLimitDisplay")
        }

        weeklyDisplayMenuItem?.isHidden = availabilityIsKnown && !weeklyAvailable
        fiveHourDisplayMenuItem?.isHidden = availabilityIsKnown && !fiveHourAvailable
        weeklyDisplayMenuItem?.state = mode == .weekly ? .on : .off
        fiveHourDisplayMenuItem?.state = mode == .fiveHour ? .on : .off

        let statusWindow: CodexLimitWindow?
        let savedUsedPercent: Double?
        let shortLabel: String
        let summaryLabel: String
        let descriptiveLabel: String
        switch mode {
        case .weekly:
            statusWindow = weeklyWindow
            let savedAvailable = defaults.object(forKey: "sevenDayAvailablePercent") as? Double
            savedUsedPercent = savedAvailable.flatMap { $0 >= 0 ? 100 - $0 : nil }
            shortLabel = "7d余"
            summaryLabel = "7d可用"
            descriptiveLabel = "7天余量"
        case .fiveHour:
            statusWindow = fiveHourWindow
            let savedUsed = defaults.object(forKey: "fiveHourUsagePercent") as? Double
            savedUsedPercent = savedUsed.flatMap { $0 >= 0 ? $0 : nil }
            shortLabel = "5H余"
            summaryLabel = "5H可用"
            descriptiveLabel = "5小时余量"
        }

        let usedPercent = statusWindow?.usedPercent ?? savedUsedPercent
        guard let usedPercent else {
            statusItem?.button?.title = "\(shortLabel)--"
            statusItem?.button?.toolTip = "Codex 当前没有提供\(descriptiveLabel)"
            let syncText = lastFastSyncDate.map { "\(menuBarSecondFormatter.string(from: $0))同步" } ?? "同步待更新"
            statusSummaryMenuItem?.title = "\(summaryLabel) -- · 当前未提供 · \(syncText)"
            return
        }

        let remaining = max(0, min(100, 100 - usedPercent))
        let title = "\(shortLabel)\(Int(remaining.rounded()))%"
        if statusItem?.button?.title != title {
            statusItem?.button?.title = title
        }
        let resetText = statusWindow?.resetsAt
            .flatMap { $0 > Date() ? "\(menuBarTimeFormatter.string(from: $0))刷新" : nil }
            ?? "刷新待更新"
        let syncText = lastFastSyncDate.map { "\(menuBarSecondFormatter.string(from: $0))同步" } ?? "同步待更新"
        statusItem?.button?.toolTip = "Codex \(descriptiveLabel) \(formatPercent(remaining)) · \(resetText) · \(syncText)"
        statusSummaryMenuItem?.title = "\(summaryLabel) \(Int(remaining.rounded()))% · \(resetText) · \(syncText)"
    }

    private func seedDefaultsIfNeeded() {
        let savedVersion = UserDefaults.standard.object(forKey: "dataContractVersion") as? Int ?? 0
        let defaults: [String: Any] = [
            "dataContractVersion": 7,
            "dataMode": "Codex 未连接",
            "renewalDate": "",
            "todayInput": -1,
            "todayOutput": -1,
            "todayCache": -1,
            "fiveHourUsed": -1,
            "fiveHourUsagePercent": -1.0,
            "sevenDayAvailablePercent": -1.0,
            "menuBarLimitDisplay": MenuBarLimitDisplay.weekly.rawValue,
            "dailyTokens": "",
            "lastSyncISO": "",
            "fetchError": "",
            "theme": "graphite"
        ]
        UserDefaults.standard.register(defaults: defaults)

        if savedVersion < 6 {
            let clearedValues: [String: Any] = [
                "dataMode": "Codex 未连接",
                "todayInput": -1,
                "todayOutput": -1,
                "todayCache": -1,
                "fiveHourUsed": -1,
                "fiveHourUsagePercent": -1.0,
                "sevenDayAvailablePercent": -1.0,
                "dailyTokens": "",
                "lastSyncISO": "",
                "fetchError": ""
            ]
            for (key, value) in clearedValues {
                UserDefaults.standard.set(value, forKey: key)
            }
            UserDefaults.standard.removeObject(forKey: "fiveHourBudget")
            UserDefaults.standard.removeObject(forKey: "weekBudget")
            UserDefaults.standard.removeObject(forKey: "monthBudget")
            UserDefaults.standard.removeObject(forKey: "monthTotal")
        }

        if savedVersion < 4 {
            UserDefaults.standard.set("graphite", forKey: "theme")
        }
        UserDefaults.standard.set(7, forKey: "dataContractVersion")
    }
}

struct UsageWidgetView: View {
    @AppStorage("dataMode") private var dataMode = "Codex 未连接"
    @AppStorage("renewalDate") private var renewalDate = ""
    @AppStorage("todayInput") private var todayInput = -1
    @AppStorage("todayOutput") private var todayOutput = -1
    @AppStorage("todayCache") private var todayCache = -1
    @AppStorage("fiveHourUsed") private var fiveHourUsed = -1
    @AppStorage("fiveHourUsagePercent") private var fiveHourUsagePercent = -1.0
    @AppStorage("sevenDayAvailablePercent") private var sevenDayAvailablePercent = -1.0
    @AppStorage("dailyTokens") private var dailyTokens = ""
    @AppStorage("lastSyncISO") private var lastSyncISO = ""
    @AppStorage("fetchError") private var fetchError = ""
    @AppStorage("theme") private var theme = "graphite"

    @State private var showingSettings = false
    @State private var isRefreshingUsage = false

    private var palette: Palette { Palette.named(theme) }
    private var todayTotal: Int? {
        guard todayInput >= 0, todayOutput >= 0 else { return nil }
        return todayInput + todayOutput
    }
    private var dailyValues: [Int] {
        parseDailyTokens(dailyTokens)
    }
    private var weekTotal: Int? {
        guard dailyValues.count == 7 else { return nil }
        return dailyValues.reduce(0, +)
    }
    private var rollingDailyAverage: Int? {
        guard let weekTotal else { return nil }
        return Int((Double(weekTotal) / 7.0).rounded())
    }

    var body: some View {
        ZStack {
            TechField(palette: palette)
                .allowsHitTesting(false)

            VStack(spacing: 13) {
                header
                statusStrip
                renewalPanel
                periodRings
                rollingAveragePanel
                todayPanel
                footer
            }
            .padding(18)
        }
        .frame(width: 400, height: 590)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.panel.opacity(0.94))
                .overlay(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.055),
                            palette.primary.opacity(0.07),
                            Color.black.opacity(0.16)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.line.opacity(0.9), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .onAppear {
            writeSharedSnapshotFromState()
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView(
                dataMode: $dataMode,
                renewalDate: $renewalDate,
                todayInput: $todayInput,
                todayOutput: $todayOutput,
                todayCache: $todayCache,
                fiveHourUsed: $fiveHourUsed,
                fiveHourUsagePercent: $fiveHourUsagePercent,
                sevenDayAvailablePercent: $sevenDayAvailablePercent,
                dailyTokens: $dailyTokens,
                lastSyncISO: $lastSyncISO,
                fetchError: $fetchError,
                theme: $theme
            )
            .frame(width: 430)
        }
        .onChange(of: theme) {
            writeSharedSnapshotFromState()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 5) {
                Text("本机小组件 · 用量观测")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text("Codex计费")
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                showingSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 38, height: 38)
                    .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(Color.white.opacity(0.16), lineWidth: 1)
                    )
            }
            .buttonStyle(.plain)
            .help("设置")
        }
    }

    private var statusStrip: some View {
        HStack(spacing: 8) {
            Chip(label: "数据源", value: dataMode)
            Chip(label: "周期", value: "5H / 7D")
        }
    }

    private var renewalPanel: some View {
        let days = daysUntilRenewal(renewalDate)

        return HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("Pro 续费")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(renewalDateText(renewalDate))
                    .font(.system(size: 20, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(renewalCount(days))
                    .font(.system(size: 32, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Text(renewalSuffix(days))
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 78, alignment: .trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(height: 64)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(palette.panel.opacity(0.55))
                .overlay(
                    LinearGradient(
                        colors: [palette.primary.opacity(0.10), .clear, palette.warm.opacity(0.055)],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.line.opacity(0.8), lineWidth: 1)
        )
    }

    private var periodRings: some View {
        HStack(spacing: 12) {
            GaugeTile(
                title: "5小时可用量",
                budgetText: fiveHourUsed >= 0 ? "\(formatToken(fiveHourUsed)) Token" : "Codex 日志",
                valueText: formatAvailablePercent(fromUsed: fiveHourUsagePercent),
                percentText: fiveHourUsagePercent >= 0 ? "5H 剩余" : "未读取",
                ratio: availableRatio(fromUsed: fiveHourUsagePercent),
                palette: palette,
                accentIndex: 0
            )

            GaugeTile(
                title: "7天可用量",
                budgetText: "滚动窗口",
                valueText: formatPercent(sevenDayAvailablePercent),
                percentText: sevenDayAvailablePercent >= 0 ? "7D 剩余" : "未读取",
                ratio: percentRatio(sevenDayAvailablePercent),
                palette: palette,
                accentIndex: 1
            )
        }
    }

    private var rollingAveragePanel: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text("7天日均")
                    .font(.system(size: 15, weight: .bold))
                Text("近 7 天平均")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack {
                Text(formatToken(rollingDailyAverage))
                    .font(.system(size: 28, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                Text("/天")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 70)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.line.opacity(0.75), lineWidth: 1)
        )
    }

    private var todayPanel: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("今日 Token")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(formatToken(todayTotal))
                    .font(.system(size: 30, weight: .heavy, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.74)
            }

            Spacer()

            HStack(spacing: 6) {
                SplitTile(label: "输入", value: formatToken(todayInput))
                SplitTile(label: "输出", value: formatToken(todayOutput))
                SplitTile(label: "缓存", value: formatToken(todayCache))
            }
            .frame(width: 196)
        }
    }

    private var footer: some View {
        HStack {
            HStack(spacing: 8) {
                Circle()
                    .fill(palette.tertiary)
                    .frame(width: 9, height: 9)
                    .shadow(color: palette.tertiary.opacity(0.8), radius: 8)
                Text("菜单栏运行")
            }

            Spacer()

            Text(lastSyncLabel(lastSyncISO))
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.top, 1)
    }

    private func writeSharedSnapshotFromState() {
        writeSharedSnapshot(
            SharedUsageSnapshot(
                dataMode: dataMode,
                renewalDate: renewalDate,
                todayInput: todayInput,
                todayOutput: todayOutput,
                todayCache: todayCache,
                fiveHourUsed: fiveHourUsed,
                fiveHourUsagePercent: fiveHourUsagePercent,
                sevenDayAvailablePercent: sevenDayAvailablePercent,
                dailyTokens: dailyTokens,
                lastSyncISO: lastSyncISO,
                fetchError: fetchError,
                theme: theme
            )
        )
    }

    private func refreshFromCodexLogsInBackgroundIfNeeded() {
        guard shouldRefreshViewUsage(maxAge: 6 * 60 * 60) else { return }
        refreshFromCodexLogsInBackground()
    }

    private func shouldRefreshViewUsage(maxAge: TimeInterval) -> Bool {
        guard !lastSyncISO.isEmpty, let lastSyncDate = isoFormatter.date(from: lastSyncISO) else {
            return true
        }
        return Date().timeIntervalSince(lastSyncDate) > maxAge
    }

    private func refreshFromCodexLogsInBackground() {
        guard !isRefreshingUsage else { return }
        isRefreshingUsage = true

        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try CodexLogUsageReader.load() }
            }.value

            switch result {
            case let .success(usage):
                dataMode = "Codex 日志"
                todayInput = usage.todayInput
                todayOutput = usage.todayOutput
                todayCache = usage.todayCached
                fiveHourUsed = usage.fiveHourTokens
                fiveHourUsagePercent = usage.fiveHourUsagePercent ?? -1
                sevenDayAvailablePercent = usage.sevenDayAvailablePercent ?? -1
                dailyTokens = usage.dailyTotals.map(String.init).joined(separator: "\n")
                lastSyncISO = isoFormatter.string(from: Date())
                fetchError = ""
            case let .failure(error):
                dataMode = "Codex 未连接"
                todayInput = -1
                todayOutput = -1
                todayCache = -1
                fiveHourUsed = -1
                fiveHourUsagePercent = -1
                sevenDayAvailablePercent = -1
                dailyTokens = ""
                lastSyncISO = ""
                fetchError = error.localizedDescription
            }
            isRefreshingUsage = false
            writeSharedSnapshotFromState()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

struct SettingsView: View {
    @Binding var dataMode: String
    @Binding var renewalDate: String
    @Binding var todayInput: Int
    @Binding var todayOutput: Int
    @Binding var todayCache: Int
    @Binding var fiveHourUsed: Int
    @Binding var fiveHourUsagePercent: Double
    @Binding var sevenDayAvailablePercent: Double
    @Binding var dailyTokens: String
    @Binding var lastSyncISO: String
    @Binding var fetchError: String
    @Binding var theme: String

    @Environment(\.dismiss) private var dismiss
    @State private var statusText = ""
    @State private var isRefreshing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("小组件设置")
                    .font(.system(size: 20, weight: .bold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("关闭")
            }

            Form {
                LabeledContent("数据源") {
                    Text(dataMode)
                        .foregroundStyle(dataMode == "Codex 日志" ? .green : .secondary)
                }

                Picker("视觉主题", selection: $theme) {
                    Text("石墨冷光").tag("graphite")
                    Text("青雾矩阵").tag("mist")
                    Text("钛金仪表").tag("laboratory")
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 7) {
                    Text("Codex 用量源")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("读取本机 Codex 日志里的 token_count 事件；没有记录时保持 --。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack {
                    Button(isRefreshing ? "后台刷新中..." : "刷新数据") {
                        refreshFromCodexLogs()
                    }
                    .disabled(isRefreshing)

                    Button("重置为 --") {
                        clearUsageData()
                    }
                    .foregroundStyle(.red)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("同步状态")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(statusLine)
                        .font(.system(size: 12))
                        .foregroundStyle(fetchError.isEmpty ? Color.secondary : Color.red)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("Pro 续费日期")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                    TextField("Codex 未提供，可留空", text: $renewalDate)
                        .textFieldStyle(.roundedBorder)
                    Text("Codex 本机数据里没有读取到 Pro 续费日期；这里不会自动猜。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)

            HStack {
                Spacer()

                Button("完成") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
    }

    private var statusLine: String {
        if !statusText.isEmpty { return statusText }
        if !fetchError.isEmpty { return "同步失败：\(fetchError)" }
        if !lastSyncISO.isEmpty { return "上次同步：\(lastSyncLabel(lastSyncISO))" }
        return "未读取到 Codex 日志。不会使用示例数据。"
    }

    private func clearUsageData() {
        dataMode = "Codex 未连接"
        todayInput = -1
        todayOutput = -1
        todayCache = -1
        fiveHourUsed = -1
        fiveHourUsagePercent = -1
        sevenDayAvailablePercent = -1
        dailyTokens = ""
        lastSyncISO = ""
        fetchError = ""
        writeSharedSnapshot(
            SharedUsageSnapshot(
                dataMode: dataMode,
                renewalDate: renewalDate,
                todayInput: todayInput,
                todayOutput: todayOutput,
                todayCache: todayCache,
                fiveHourUsed: fiveHourUsed,
                fiveHourUsagePercent: fiveHourUsagePercent,
                sevenDayAvailablePercent: sevenDayAvailablePercent,
                dailyTokens: dailyTokens,
                lastSyncISO: lastSyncISO,
                fetchError: fetchError,
                theme: theme
            )
        )
        WidgetCenter.shared.reloadAllTimelines()
        statusText = "已重置为 --；没有真实 Codex 数据时不显示数字。"
    }

    private func refreshFromCodexLogs() {
        guard !isRefreshing else { return }
        isRefreshing = true
        statusText = "后台读取中，窗口可以继续操作。"

        Task {
            let result = await Task.detached(priority: .utility) {
                Result { try CodexLogUsageReader.load() }
            }.value

            switch result {
            case let .success(usage):
                dataMode = "Codex 日志"
                todayInput = usage.todayInput
                todayOutput = usage.todayOutput
                todayCache = usage.todayCached
                fiveHourUsed = usage.fiveHourTokens
                fiveHourUsagePercent = usage.fiveHourUsagePercent ?? -1
                sevenDayAvailablePercent = usage.sevenDayAvailablePercent ?? -1
                dailyTokens = usage.dailyTotals.map(String.init).joined(separator: "\n")
                lastSyncISO = isoFormatter.string(from: Date())
                fetchError = ""
                statusText = "已读取 Codex 日志：\(usage.eventCount) 条 token_count。"
            case let .failure(error):
                dataMode = "Codex 未连接"
                todayInput = -1
                todayOutput = -1
                todayCache = -1
                fiveHourUsed = -1
                fiveHourUsagePercent = -1
                sevenDayAvailablePercent = -1
                dailyTokens = ""
                lastSyncISO = ""
                fetchError = error.localizedDescription
                statusText = ""
            }

            isRefreshing = false
            writeSharedSnapshot(
                SharedUsageSnapshot(
                    dataMode: dataMode,
                    renewalDate: renewalDate,
                    todayInput: todayInput,
                    todayOutput: todayOutput,
                    todayCache: todayCache,
                    fiveHourUsed: fiveHourUsed,
                    fiveHourUsagePercent: fiveHourUsagePercent,
                    sevenDayAvailablePercent: sevenDayAvailablePercent,
                    dailyTokens: dailyTokens,
                    lastSyncISO: lastSyncISO,
                    fetchError: fetchError,
                    theme: theme
                )
            )
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}

struct NumberRow: View {
    let title: String
    @Binding var value: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("", value: $value, formatter: integerFormatter)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
        }
    }
}

struct Chip: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .fontWeight(.bold)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
        }
        .font(.system(size: 12, weight: .medium))
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

struct GaugeTile: View {
    let title: String
    let budgetText: String
    let valueText: String
    let percentText: String
    let ratio: Double?
    let palette: Palette
    let accentIndex: Int

    var body: some View {
        let progress = min(max(ratio ?? 0, 0), 1)

        VStack(spacing: 12) {
            HStack {
                Text(title)
                    .font(.system(size: 15, weight: .bold))
                Spacer()
                Text(budgetText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            ZStack {
                Circle()
                    .trim(from: 0.08, to: 0.88)
                    .stroke(palette.line.opacity(0.38), style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(126))

                Circle()
                    .trim(from: 0.08, to: 0.08 + 0.8 * progress)
                    .stroke(
                        AngularGradient(
                            colors: accentIndex == 0
                                ? [palette.primary.opacity(0.86), palette.secondary.opacity(0.78), palette.tertiary.opacity(0.82)]
                                : [palette.tertiary.opacity(0.82), palette.primary.opacity(0.76), palette.warm.opacity(0.74)],
                            center: .center
                        ),
                        style: StrokeStyle(lineWidth: 10, lineCap: .round)
                    )
                    .rotationEffect(.degrees(126))

                VStack(spacing: 4) {
                    Text(valueText)
                        .font(.system(size: 23, weight: .heavy, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.58)
                        .frame(width: 94)
                    Text(percentText)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
            }
            .frame(width: 116, height: 116)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(palette.line.opacity(0.32))
                    Capsule()
                        .fill(LinearGradient(colors: [palette.primary.opacity(0.85), palette.secondary.opacity(0.72), palette.tertiary.opacity(0.78)], startPoint: .leading, endPoint: .trailing))
                        .frame(width: proxy.size.width * progress)
                }
            }
            .frame(height: 5)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 176)
        .background(palette.panel.opacity(0.48), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.line.opacity(0.75), lineWidth: 1)
        )
    }
}

struct BarChart: View {
    let values: [Int]
    let palette: Palette

    private var maxValue: Int { max(values.max() ?? 1, 1) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ForEach(values.indices, id: \.self) { index in
                VStack(spacing: 7) {
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(Color.white.opacity(0.07))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
                            )

                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.56), palette.secondary, palette.primary, palette.tertiary],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .frame(height: max(6, CGFloat(values[index]) / CGFloat(maxValue) * 84))
                    }
                    .frame(height: 84)

                    Text(shortDate(offset: index - 6))
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .help("\(shortDate(offset: index - 6)) · \(formatToken(values[index]))")
            }
        }
        .frame(height: 112)
    }
}

struct SplitTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .padding(7)
        .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        )
    }
}

struct TechField: View {
    let palette: Palette

    var body: some View {
        ZStack {
            palette.background

            LinearGradient(
                colors: [
                    Color.white.opacity(0.035),
                    palette.primary.opacity(0.055),
                    Color.black.opacity(0.18)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Canvas { context, size in
                let minor = palette.line.opacity(0.13)
                let major = palette.line.opacity(0.22)

                for x in stride(from: 0.0, through: Double(size.width), by: 28.0) {
                    var path = Path()
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    context.stroke(path, with: .color(Int(x).isMultiple(of: 84) ? major : minor), lineWidth: 0.6)
                }

                for y in stride(from: 0.0, through: Double(size.height), by: 28.0) {
                    var path = Path()
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(path, with: .color(Int(y).isMultiple(of: 84) ? major : minor), lineWidth: 0.6)
                }

                let topLine = CGRect(x: 20, y: 18, width: size.width - 40, height: 1)
                context.fill(Path(topLine), with: .linearGradient(
                    Gradient(colors: [.clear, palette.primary.opacity(0.42), .clear]),
                    startPoint: CGPoint(x: topLine.minX, y: topLine.midY),
                    endPoint: CGPoint(x: topLine.maxX, y: topLine.midY)
                ))

                let lowerBand = CGRect(x: 0, y: size.height * 0.68, width: size.width, height: 64)
                context.fill(Path(lowerBand), with: .linearGradient(
                    Gradient(colors: [.clear, palette.secondary.opacity(0.045), .clear]),
                    startPoint: CGPoint(x: 0, y: lowerBand.minY),
                    endPoint: CGPoint(x: 0, y: lowerBand.maxY)
                ))
            }
        }
    }
}

struct SharedUsageSnapshot: Codable {
    let dataMode: String
    let renewalDate: String
    let todayInput: Int
    let todayOutput: Int
    let todayCache: Int
    let fiveHourUsed: Int
    let fiveHourUsagePercent: Double?
    let sevenDayAvailablePercent: Double?
    let dailyTokens: String
    let lastSyncISO: String
    let fetchError: String
    let theme: String
}

private func sharedSnapshotURL() throws -> URL {
    let folder = realHomeDirectory()
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("AIUsageDesklet", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder.appendingPathComponent("usage.json")
}

private func realHomeDirectory() -> URL {
    if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
}

private func writeSharedSnapshot(_ snapshot: SharedUsageSnapshot) {
    do {
        let data = try JSONEncoder().encode(snapshot)
        try data.write(to: try sharedSnapshotURL(), options: [.atomic])
    } catch {
        NSLog("AIUsageDesklet snapshot write failed: \(error.localizedDescription)")
    }
}

struct CodexLocalUsage {
    let todayInput: Int
    let todayOutput: Int
    let todayCached: Int
    let fiveHourTokens: Int
    let fiveHourUsagePercent: Double?
    let sevenDayAvailablePercent: Double?
    let dailyTotals: [Int]
    let eventCount: Int
}

private struct CodexRateLimitCandidate {
    let eventDate: Date
    let primaryUsedPercent: Double
    let secondaryUsedPercent: Double?
    let primaryResetDate: Date?
    let primaryWindowMinutes: Int?
    let secondaryWindowMinutes: Int?
    let isMainCodexLimit: Bool
}

enum CodexLogUsageError: LocalizedError {
    case sessionsFolderMissing
    case noTokenEvents

    var errorDescription: String? {
        switch self {
        case .sessionsFolderMissing:
            return "没有找到本机 Codex sessions 日志。"
        case .noTokenEvents:
            return "没有读到 Codex token_count 记录。"
        }
    }
}

struct CodexLogUsageReader {
    static func load() throws -> CodexLocalUsage {
        let fileManager = FileManager.default
        let sessionsFolder = realHomeDirectory()
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionsFolder.path) else {
            throw CodexLogUsageError.sessionsFolderMissing
        }

        let now = Date()
        let fiveHourStart = now.addingTimeInterval(-5 * 60 * 60)
        let fileCutoff = now.addingTimeInterval(-9 * 24 * 60 * 60)
        let calendar = Calendar.current
        let todayStart = calendar.startOfDay(for: now)
        let firstDay = calendar.date(byAdding: .day, value: -6, to: todayStart) ?? todayStart
        let dailyKeys = (0..<7).compactMap { calendar.date(byAdding: .day, value: $0, to: firstDay) }
        var dailyTotals = Dictionary(uniqueKeysWithValues: dailyKeys.map { ($0, 0) })

        var todayInput = 0
        var todayOutput = 0
        var todayCached = 0
        var fiveHourTokens = 0
        var eventCount = 0
        var rateLimitCandidates: [CodexRateLimitCandidate] = []

        guard let enumerator = fileManager.enumerator(
            at: sessionsFolder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CodexLogUsageError.sessionsFolderMissing
        }

        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            guard values.isRegularFile == true else { continue }
            if let modified = values.contentModificationDate, modified < fileCutoff { continue }
            try? scanTokenLines(in: fileURL) { line in
                autoreleasepool {
                    guard let data = line.data(using: .utf8) else { return }
                    guard
                        let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        object["type"] as? String == "event_msg",
                        let payload = object["payload"] as? [String: Any],
                        payload["type"] as? String == "token_count",
                        let timestamp = object["timestamp"] as? String,
                        let date = parseCodexLogDate(timestamp),
                        let info = payload["info"] as? [String: Any],
                        let usage = info["last_token_usage"] as? [String: Any]
                    else { return }

                    let input = intValue(usage["input_tokens"])
                    let output = intValue(usage["output_tokens"])
                    let cached = intValue(usage["cached_input_tokens"])
                    let total = intValue(usage["total_tokens"])
                    let day = calendar.startOfDay(for: date)

                    if dailyTotals.keys.contains(day) {
                        dailyTotals[day, default: 0] += total
                    }
                    if day == todayStart {
                        todayInput += input
                        todayOutput += output
                        todayCached += cached
                    }
                    if date >= fiveHourStart {
                        fiveHourTokens += total
                    }
                    if let rateLimits = payload["rate_limits"] as? [String: Any],
                       let primary = rateLimits["primary"] as? [String: Any],
                       let primaryUsed = doubleValue(primary["used_percent"]) {
                        let secondary = rateLimits["secondary"] as? [String: Any]
                        let secondaryUsed = secondary
                            .flatMap { doubleValue($0["used_percent"]) }
                        let limitID = rateLimits["limit_id"] as? String
                        rateLimitCandidates.append(
                            CodexRateLimitCandidate(
                                eventDate: date,
                                primaryUsedPercent: primaryUsed,
                                secondaryUsedPercent: secondaryUsed,
                                primaryResetDate: doubleValue(primary["resets_at"]).map { Date(timeIntervalSince1970: $0) },
                                primaryWindowMinutes: optionalIntValue(primary["window_minutes"]),
                                secondaryWindowMinutes: secondary.flatMap { optionalIntValue($0["window_minutes"]) },
                                isMainCodexLimit: limitID == "codex"
                            )
                        )
                    }
                    eventCount += 1
                }
            }
        }

        guard eventCount > 0 else { throw CodexLogUsageError.noTokenEvents }

        let orderedDailyTotals = dailyKeys.map { dailyTotals[$0, default: 0] }
        let selectedRateLimit = selectedRateLimitCandidate(from: rateLimitCandidates, now: now)
        let fiveHourUsed = selectedRateLimit.flatMap { candidate -> Double? in
            if candidate.primaryWindowMinutes == 300 { return candidate.primaryUsedPercent }
            if candidate.secondaryWindowMinutes == 300 { return candidate.secondaryUsedPercent }
            return nil
        }
        let weeklyUsed = selectedRateLimit.flatMap { candidate -> Double? in
            if candidate.primaryWindowMinutes == 10_080 { return candidate.primaryUsedPercent }
            if candidate.secondaryWindowMinutes == 10_080 { return candidate.secondaryUsedPercent }
            return nil
        }
        let sevenDayAvailable = weeklyUsed.map { clampPercent(100.0 - $0) }

        return CodexLocalUsage(
            todayInput: todayInput,
            todayOutput: todayOutput,
            todayCached: todayCached,
            fiveHourTokens: fiveHourTokens,
            fiveHourUsagePercent: fiveHourUsed.map(clampPercent),
            sevenDayAvailablePercent: sevenDayAvailable,
            dailyTotals: orderedDailyTotals,
            eventCount: eventCount
        )
    }

    private static func intValue(_ value: Any?) -> Int {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) ?? 0 }
        return 0
    }

    private static func optionalIntValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func selectedRateLimitCandidate(
        from candidates: [CodexRateLimitCandidate],
        now: Date
    ) -> CodexRateLimitCandidate? {
        let activeCandidates = candidates.filter { candidate in
            guard let resetDate = candidate.primaryResetDate else { return false }
            return resetDate > now
        }
        if let activeMain = latestCandidate(activeCandidates.filter(\.isMainCodexLimit)) {
            return activeMain
        }
        if let latestMain = candidates.filter(\.isMainCodexLimit).max(by: { $0.eventDate < $1.eventDate }) {
            return latestMain
        }
        return nil
    }

    private static func latestCandidate(_ candidates: [CodexRateLimitCandidate]) -> CodexRateLimitCandidate? {
        candidates.max(by: { $0.eventDate < $1.eventDate })
    }

    private static func parseCodexLogDate(_ value: String) -> Date? {
        logDateFormatterWithFractionalSeconds.date(from: value) ?? logDateFormatter.date(from: value)
    }

    private static func scanTokenLines(in fileURL: URL, _ body: (String) -> Void) throws {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let marker = Data(#""token_count""#.utf8)
        var buffer = Data()
        let chunkSize = 64 * 1024

        while true {
            guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else { break }
            buffer.append(chunk)

            while let newline = buffer.firstIndex(of: 10) {
                let lineData = buffer[..<newline]
                processLineData(lineData, marker: marker, body)
                buffer.removeSubrange(buffer.startIndex...newline)
            }

            if buffer.count > 2 * 1024 * 1024 {
                buffer.removeAll(keepingCapacity: true)
            }
        }

        if !buffer.isEmpty {
            processLineData(buffer[buffer.startIndex..<buffer.endIndex], marker: marker, body)
        }
    }

    private static func processLineData(_ lineData: Data.SubSequence, marker: Data, _ body: (String) -> Void) {
        guard lineData.range(of: marker) != nil else { return }
        var data = Data(lineData)
        if data.last == 13 {
            data.removeLast()
        }
        guard let line = String(data: data, encoding: .utf8) else { return }
        body(line)
    }

    private static let logDateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

struct CodexFastLimitStatus {
    let usedPercent: Double
    let secondaryUsedPercent: Double?
    let resetsAt: Date?
    let secondaryResetsAt: Date?
    let primaryWindowMinutes: Int?
    let secondaryWindowMinutes: Int?
    let eventDate: Date
    let isMainCodexLimit: Bool
    let isAuthoritative: Bool
}

struct CodexLimitWindow {
    let usedPercent: Double
    let resetsAt: Date?
}

extension CodexFastLimitStatus {
    func window(minutes: Int) -> CodexLimitWindow? {
        if primaryWindowMinutes == minutes {
            return CodexLimitWindow(usedPercent: usedPercent, resetsAt: resetsAt)
        }
        if secondaryWindowMinutes == minutes, let secondaryUsedPercent {
            return CodexLimitWindow(usedPercent: secondaryUsedPercent, resetsAt: secondaryResetsAt)
        }
        return nil
    }
}

func resolvedMenuBarLimitDisplay(
    preferred: MenuBarLimitDisplay,
    weeklyAvailable: Bool,
    fiveHourAvailable: Bool
) -> MenuBarLimitDisplay {
    switch preferred {
    case .weekly where !weeklyAvailable && fiveHourAvailable:
        return .fiveHour
    case .fiveHour where !fiveHourAvailable && weeklyAvailable:
        return .weekly
    default:
        return preferred
    }
}

struct CodexFastLimitReader {
    static func loadLatestFiveHourLimitStatus() throws -> CodexFastLimitStatus {
        let fileManager = FileManager.default
        let sessionsFolder = realHomeDirectory()
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        guard fileManager.fileExists(atPath: sessionsFolder.path) else {
            throw CodexLogUsageError.sessionsFolderMissing
        }

        let recentFiles = try latestSessionFiles(in: sessionsFolder, limit: 8)
        var statuses: [CodexFastLimitStatus] = []

        for fileURL in recentFiles {
            statuses.append(contentsOf: try latestPrimaryLimitStatuses(inTailOf: fileURL))
        }

        if let status = selectedStatus(from: statuses, now: Date()) {
            return CodexFastLimitStatus(
                usedPercent: clampPercent(status.usedPercent),
                secondaryUsedPercent: status.secondaryUsedPercent.map(clampPercent),
                resetsAt: status.resetsAt,
                secondaryResetsAt: status.secondaryResetsAt,
                primaryWindowMinutes: status.primaryWindowMinutes,
                secondaryWindowMinutes: status.secondaryWindowMinutes,
                eventDate: status.eventDate,
                isMainCodexLimit: status.isMainCodexLimit,
                isAuthoritative: false
            )
        }
        throw CodexLogUsageError.noTokenEvents
    }

    static func latestSessionFiles(in folder: URL, limit: Int) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            throw CodexLogUsageError.sessionsFolderMissing
        }

        var files: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl" else { continue }
            guard let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]) else { continue }
            guard values.isRegularFile == true else { continue }
            files.append((fileURL, values.contentModificationDate ?? .distantPast))
        }

        return files
            .sorted { $0.modified > $1.modified }
            .prefix(limit)
            .map { $0.url }
    }

    private static func latestPrimaryLimitStatuses(inTailOf fileURL: URL) throws -> [CodexFastLimitStatus] {
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }

        let fileSize = try handle.seekToEnd()
        let maxTailBytes: UInt64 = 96 * 1024
        let start = fileSize > maxTailBytes ? fileSize - maxTailBytes : 0
        try handle.seek(toOffset: start)
        let tailData = try handle.readToEnd() ?? Data()
        guard !tailData.isEmpty else { return [] }

        var statuses: [CodexFastLimitStatus] = []
        let marker = Data(#""token_count""#.utf8)
        var lineEnd = tailData.endIndex

        while lineEnd > tailData.startIndex {
            let searchRange = tailData.startIndex..<lineEnd
            let lineStart: Data.Index
            if let newlineIndex = tailData[searchRange].lastIndex(of: 10) {
                lineStart = tailData.index(after: newlineIndex)
            } else {
                lineStart = tailData.startIndex
            }

            if lineStart < lineEnd {
                var lineData = tailData[lineStart..<lineEnd]
                if lineData.last == 13 {
                    lineData = lineData.dropLast()
                }
                if lineData.range(of: marker) != nil,
                   let line = String(data: Data(lineData), encoding: .utf8),
                   let status = primaryLimitStatus(fromJSONLine: line) {
                    statuses.append(status)
                }
            }

            guard lineStart > tailData.startIndex else { break }
            lineEnd = tailData.index(before: lineStart)
            if statuses.count >= 80 {
                break
            }
        }

        return statuses
    }

    private static func primaryLimitStatus(fromJSONLine line: String) -> CodexFastLimitStatus? {
        guard
            let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            object["type"] as? String == "event_msg",
            let payload = object["payload"] as? [String: Any],
            payload["type"] as? String == "token_count",
            let timestamp = object["timestamp"] as? String,
            let eventDate = parseCodexLogDate(timestamp),
            let rateLimits = payload["rate_limits"] as? [String: Any],
            let primary = rateLimits["primary"] as? [String: Any]
        else {
            return nil
        }

        guard let usedPercent = doubleValue(primary["used_percent"]) else { return nil }
        let secondary = rateLimits["secondary"] as? [String: Any]
        let secondaryUsedPercent = secondary.flatMap { doubleValue($0["used_percent"]) }
        let resetDate = doubleValue(primary["resets_at"]).map { Date(timeIntervalSince1970: $0) }
        let primaryWindowMinutes = intValue(primary["window_minutes"])
        let secondaryResetDate = secondary
            .flatMap { doubleValue($0["resets_at"]) }
            .map { Date(timeIntervalSince1970: $0) }
        let secondaryWindowMinutes = secondary.flatMap { intValue($0["window_minutes"]) }
        return CodexFastLimitStatus(
            usedPercent: usedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            resetsAt: resetDate,
            secondaryResetsAt: secondaryResetDate,
            primaryWindowMinutes: primaryWindowMinutes,
            secondaryWindowMinutes: secondaryWindowMinutes,
            eventDate: eventDate,
            isMainCodexLimit: rateLimits["limit_id"] as? String == "codex",
            isAuthoritative: false
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private static func selectedStatus(from statuses: [CodexFastLimitStatus], now: Date) -> CodexFastLimitStatus? {
        let activeStatuses = statuses.filter { status in
            guard let resetDate = status.resetsAt else { return false }
            return resetDate > now
        }
        if let activeMain = latestStatus(activeStatuses.filter(\.isMainCodexLimit)) {
            return activeMain
        }
        if let latestMain = statuses.filter(\.isMainCodexLimit).max(by: { $0.eventDate < $1.eventDate }) {
            return latestMain
        }
        return nil
    }

    private static func latestStatus(_ statuses: [CodexFastLimitStatus]) -> CodexFastLimitStatus? {
        statuses.max(by: { $0.eventDate < $1.eventDate })
    }

    private static func parseCodexLogDate(_ value: String) -> Date? {
        logDateFormatterWithFractionalSeconds.date(from: value) ?? logDateFormatter.date(from: value)
    }

    private static let logDateFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let logDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}

enum CodexRPCUsageError: Error {
    case executableMissing
    case timeout
    case closedPipe
    case malformedResponse
}

struct CodexRPCUsageReader {
    static func loadCurrentLimitStatus() throws -> CodexFastLimitStatus {
        guard let executableURL = codexExecutableURL() else {
            throw CodexRPCUsageError.executableMissing
        }

        let process = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        defer {
            try? inputPipe.fileHandleForWriting.close()
            if process.isRunning {
                process.terminate()
            }
        }

        let reader = CodexRPCLineReader(fileDescriptor: outputPipe.fileHandleForReading.fileDescriptor)
        try send(
            [
                "id": 1,
                "method": "initialize",
                "params": [
                    "clientInfo": [
                        "name": "ai-usage-desklet",
                        "version": "1.0"
                    ]
                ]
            ],
            to: inputPipe.fileHandleForWriting
        )
        _ = try response(id: 1, reader: reader, timeout: 8)

        try send(["method": "initialized", "params": [:]], to: inputPipe.fileHandleForWriting)
        try send(
            ["id": 2, "method": "account/rateLimits/read", "params": [:]],
            to: inputPipe.fileHandleForWriting
        )
        let message = try response(id: 2, reader: reader, timeout: 4)

        guard
            let result = message["result"] as? [String: Any],
            let fallbackLimits = result["rateLimits"] as? [String: Any]
        else {
            throw CodexRPCUsageError.malformedResponse
        }

        let limitsByID = result["rateLimitsByLimitId"] as? [String: Any]
        let limits = limitsByID?["codex"] as? [String: Any] ?? fallbackLimits
        guard
            let primary = limits["primary"] as? [String: Any],
            let usedPercent = doubleValue(primary["usedPercent"])
        else {
            throw CodexRPCUsageError.malformedResponse
        }

        let secondary = limits["secondary"] as? [String: Any]
        let secondaryUsedPercent = secondary.flatMap { doubleValue($0["usedPercent"]) }
        let resetsAt = doubleValue(primary["resetsAt"]).map { Date(timeIntervalSince1970: $0) }
        let primaryWindowMinutes = intValue(primary["windowDurationMins"])
        let secondaryResetsAt = secondary
            .flatMap { doubleValue($0["resetsAt"]) }
            .map { Date(timeIntervalSince1970: $0) }
        let secondaryWindowMinutes = secondary.flatMap { intValue($0["windowDurationMins"]) }
        return CodexFastLimitStatus(
            usedPercent: usedPercent,
            secondaryUsedPercent: secondaryUsedPercent,
            resetsAt: resetsAt,
            secondaryResetsAt: secondaryResetsAt,
            primaryWindowMinutes: primaryWindowMinutes,
            secondaryWindowMinutes: secondaryWindowMinutes,
            eventDate: Date(),
            isMainCodexLimit: true,
            isAuthoritative: true
        )
    }

    static func codexExecutableURL() -> URL? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/Applications/Codex.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        return candidates
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
            .map(URL.init(fileURLWithPath:))
    }

    private static func send(_ object: [String: Any], to handle: FileHandle) throws {
        var data = try JSONSerialization.data(withJSONObject: object)
        data.append(10)
        try handle.write(contentsOf: data)
    }

    private static func response(
        id: Int,
        reader: CodexRPCLineReader,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let message = try reader.readMessage(deadline: deadline)
            if let number = message["id"] as? NSNumber, number.intValue == id {
                if message["error"] != nil {
                    throw CodexRPCUsageError.malformedResponse
                }
                return message
            }
        }
        throw CodexRPCUsageError.timeout
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

final class CodexRPCLineReader {
    private let fileDescriptor: Int32
    private var buffer = Data()

    init(fileDescriptor: Int32) {
        self.fileDescriptor = fileDescriptor
    }

    func readMessage(deadline: Date) throws -> [String: Any] {
        while true {
            if let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline])
                buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                if let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                    return object
                }
                continue
            }

            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw CodexRPCUsageError.timeout }
            let remainingMilliseconds = Int32(max(1, remaining * 1_000))
            var descriptor = pollfd(fd: fileDescriptor, events: Int16(POLLIN), revents: 0)
            let pollResult = poll(&descriptor, 1, remainingMilliseconds)
            if pollResult == 0 { throw CodexRPCUsageError.timeout }
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw CodexRPCUsageError.closedPipe
            }

            var bytes = [UInt8](repeating: 0, count: 8_192)
            let count = bytes.withUnsafeMutableBytes { rawBuffer in
                Darwin.read(fileDescriptor, rawBuffer.baseAddress, rawBuffer.count)
            }
            guard count > 0 else { throw CodexRPCUsageError.closedPipe }
            buffer.append(contentsOf: bytes.prefix(count))
        }
    }
}

final class CodexSessionChangeMonitor {
    private let callback: () -> Void
    private let queue = DispatchQueue(label: "local.codex.ai-usage-desklet.session-monitor", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var maintenanceTimer: DispatchSourceTimer?
    private var refreshScheduled = false
    private var nextAllowedRefreshUptime: UInt64 = 0
    private var isStopped = false

    init(callback: @escaping () -> Void) {
        self.callback = callback
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !isStopped else { return }
            rebuildSources()
            scheduleRefresh(afterMilliseconds: 75)

            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 15, repeating: 15, leeway: .seconds(2))
            timer.setEventHandler { [weak self] in
                guard let self, !isStopped else { return }
                rebuildSources()
                scheduleRefresh(afterMilliseconds: 75)
            }
            maintenanceTimer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self, !isStopped else { return }
            isStopped = true
            refreshScheduled = false
            maintenanceTimer?.cancel()
            maintenanceTimer = nil
            sources.forEach { $0.cancel() }
            sources.removeAll()
        }
    }

    private func rebuildSources() {
        sources.forEach { $0.cancel() }
        sources.removeAll()

        let sessionsFolder = realHomeDirectory()
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("sessions", isDirectory: true)
        let files = (try? CodexFastLimitReader.latestSessionFiles(in: sessionsFolder, limit: 6)) ?? []

        var watchedURLs = files
        watchedURLs.append(contentsOf: Set(files.map { $0.deletingLastPathComponent() }))
        watchedURLs.append(sessionsFolder)

        for url in Set(watchedURLs) {
            let descriptor = open(url.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }

            let source = DispatchSource.makeFileSystemObjectSource(
                fileDescriptor: descriptor,
                eventMask: [.write, .extend, .rename, .delete],
                queue: queue
            )
            source.setEventHandler { [weak self] in
                self?.scheduleRefresh(afterMilliseconds: 75)
            }
            source.setCancelHandler {
                close(descriptor)
            }
            sources.append(source)
            source.resume()
        }
    }

    private func scheduleRefresh(afterMilliseconds delay: Int) {
        guard !isStopped, !refreshScheduled else { return }
        refreshScheduled = true
        let now = DispatchTime.now().uptimeNanoseconds
        let requested = now + UInt64(max(0, delay)) * 1_000_000
        let deadline = max(requested, nextAllowedRefreshUptime)
        queue.asyncAfter(deadline: DispatchTime(uptimeNanoseconds: deadline)) { [weak self] in
            guard let self else { return }
            refreshScheduled = false
            guard !isStopped else { return }
            nextAllowedRefreshUptime = DispatchTime.now().uptimeNanoseconds + 300_000_000
            callback()
        }
    }
}

struct Palette {
    let primary: Color
    let secondary: Color
    let tertiary: Color
    let warm: Color
    let background: Color
    let panel: Color
    let line: Color

    static func named(_ name: String) -> Palette {
        switch name {
        case "mist":
            return Palette(
                primary: Color(hex: 0x8bb8a8),
                secondary: Color(hex: 0x6f8fa2),
                tertiary: Color(hex: 0xb4ad86),
                warm: Color(hex: 0xb7a77f),
                background: Color(hex: 0x07110f),
                panel: Color(hex: 0x101d1a),
                line: Color(hex: 0x2d463e)
            )
        case "laboratory":
            return Palette(
                primary: Color(hex: 0xb0a171),
                secondary: Color(hex: 0x879294),
                tertiary: Color(hex: 0xac8f7f),
                warm: Color(hex: 0xc0ad78),
                background: Color(hex: 0x11100e),
                panel: Color(hex: 0x1d1a16),
                line: Color(hex: 0x4b4435)
            )
        default:
            return Palette(
                primary: Color(hex: 0x83a9b8),
                secondary: Color(hex: 0x6f7f8d),
                tertiary: Color(hex: 0x9fb7b0),
                warm: Color(hex: 0xa79a7c),
                background: Color(hex: 0x080c10),
                panel: Color(hex: 0x111820),
                line: Color(hex: 0x2c3942)
            )
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}

private let integerFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimum = 0
    formatter.maximumFractionDigits = 0
    return formatter
}()

private let percentFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = 1
    return formatter
}()

private let isoFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

private let menuBarTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm"
    return formatter
}()

private let menuBarSecondFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()

private func parseDailyTokens(_ text: String) -> [Int] {
    let values = text
        .components(separatedBy: CharacterSet(charactersIn: "\n,， "))
        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .filter { $0 >= 0 }

    guard values.count >= 7 else { return values }
    return Array(values.suffix(7))
}

private func formatToken(_ value: Int) -> String {
    guard value >= 0 else { return "--" }
    return formatChineseApproximation(max(0, value))
}

private func formatToken(_ value: Int?) -> String {
    guard let value else { return "--" }
    return formatToken(value)
}

private func formatPercent(_ value: Double) -> String {
    guard value >= 0 else { return "--" }
    let text = percentFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value.rounded()))"
    return "\(text)%"
}

private func formatPercent(_ value: Double?) -> String {
    guard let value else { return "--" }
    return formatPercent(value)
}

private func formatAvailablePercent(fromUsed value: Double) -> String {
    guard value >= 0 else { return "--" }
    return formatPercent(max(0, min(100, 100 - value)))
}

private func percentRatio(_ value: Double) -> Double? {
    guard value >= 0 else { return nil }
    return min(1, max(0, value / 100.0))
}

private func availableRatio(fromUsed value: Double) -> Double? {
    guard value >= 0 else { return nil }
    return min(1, max(0, (100 - value) / 100.0))
}

private func formatChineseApproximation(_ value: Int) -> String {
    if value < 10_000 {
        return "\(value)"
    }

    if value < 100_000 {
        var wan = value / 10_000
        var qian = ((value % 10_000) + 500) / 1_000
        if qian == 10 {
            wan += 1
            qian = 0
        }
        return qian > 0 ? "\(wan)万\(qian)千" : "\(wan)万"
    }

    if value < 10_000_000 {
        let wan = (value + 5_000) / 10_000
        return "\(wan)万"
    }

    if value < 100_000_000 {
        let wan = ((value + 50_000) / 100_000) * 10
        if wan >= 10_000 { return "1亿" }
        return "\(wan)万"
    }

    if value < 1_000_000_000 {
        var yi = value / 100_000_000
        var qianwan = ((value % 100_000_000) + 5_000_000) / 10_000_000
        if qianwan == 10 {
            yi += 1
            qianwan = 0
        }
        return qianwan > 0 ? "\(yi)亿\(qianwan)千万" : "\(yi)亿"
    }

    let yi = (value + 50_000_000) / 100_000_000
    return "\(yi)亿"
}

private func lastSyncLabel(_ value: String) -> String {
    guard !value.isEmpty, let date = isoFormatter.date(from: value) else {
        return "未同步"
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "zh_CN")
    formatter.dateFormat = "M月d日 HH:mm"
    return formatter.string(from: date)
}

private func shortDate(offset: Int) -> String {
    let calendar = Calendar.current
    let date = calendar.date(byAdding: .day, value: offset, to: Date()) ?? Date()
    let month = calendar.component(.month, from: date)
    let day = calendar.component(.day, from: date)
    return "\(month)/\(day)"
}

private func renewalDateText(_ value: String) -> String {
    guard let date = dateFromISO(value) else { return "待填写" }
    let calendar = Calendar.current
    return "\(calendar.component(.year, from: date))年\(calendar.component(.month, from: date))月\(calendar.component(.day, from: date))日"
}

private func daysUntilRenewal(_ value: String) -> Int? {
    guard let target = dateFromISO(value) else { return nil }
    let calendar = Calendar.current
    let today = calendar.startOfDay(for: Date())
    let targetDay = calendar.startOfDay(for: target)
    return calendar.dateComponents([.day], from: today, to: targetDay).day
}

private func renewalCount(_ days: Int?) -> String {
    guard let days else { return "--" }
    if days == 0 { return "今" }
    return "\(abs(days))"
}

private func renewalSuffix(_ days: Int?) -> String {
    guard let days else { return "剩余天数" }
    if days < 0 { return "已过天数" }
    if days == 0 { return "今天续费" }
    return "剩余天数"
}

private func dateFromISO(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: trimmed)
}
