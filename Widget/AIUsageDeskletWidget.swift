import Foundation
import Darwin
import SwiftUI
import WidgetKit

struct UsageEntry: TimelineEntry {
    let date: Date
    let snapshot: SharedUsageSnapshot?
}

struct UsageProvider: TimelineProvider {
    func placeholder(in context: Context) -> UsageEntry {
        UsageEntry(date: Date(), snapshot: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (UsageEntry) -> Void) {
        completion(UsageEntry(date: Date(), snapshot: readSharedSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<UsageEntry>) -> Void) {
        let entry = UsageEntry(date: Date(), snapshot: readSharedSnapshot())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct AIUsageDeskletWidget: Widget {
    let kind = "AIUsageDeskletWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: UsageProvider()) { entry in
            UsageWidgetEntryView(entry: entry)
                .containerBackground(for: .widget) {
                    WidgetChrome(palette: WidgetPalette.named(entry.snapshot?.theme ?? "graphite"))
                }
        }
        .configurationDisplayName("Codex计费")
        .description("显示 Codex 真实来源同步后的 Token 用量。")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

@main
struct AIUsageDeskletWidgetBundle: WidgetBundle {
    var body: some Widget {
        AIUsageDeskletWidget()
    }
}

struct UsageWidgetEntryView: View {
    let entry: UsageEntry
    @Environment(\.widgetFamily) private var family

    private var snapshot: SharedUsageSnapshot? { entry.snapshot }
    private var palette: WidgetPalette { WidgetPalette.named(snapshot?.theme ?? "graphite") }
    private var isConnected: Bool { snapshot?.dataMode == "Codex 日志" }
    private var todayTotal: Int? {
        guard
            let snapshot,
            snapshot.todayInput >= 0,
            snapshot.todayOutput >= 0
        else { return nil }
        return snapshot.todayInput + snapshot.todayOutput
    }
    private var rollingAverage: Int? {
        let values = parseDailyTokens(snapshot?.dailyTokens ?? "")
        guard values.count == 7 else { return nil }
        return Int((Double(values.reduce(0, +)) / 7.0).rounded())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: family == .systemSmall ? 10 : 12) {
            header

            if family == .systemSmall {
                compactMetrics
            } else {
                mediumMetrics
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(family == .systemSmall ? 14 : 16)
        .foregroundStyle(palette.text)
    }

    private var header: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex计费")
                    .font(.system(size: 15, weight: .bold))
                Text(isConnected ? "Codex 日志" : "Codex 未接入")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(palette.muted)
            }

            Spacer(minLength: 0)

            Circle()
                .fill(isConnected ? palette.primary : palette.subtle)
                .frame(width: 7, height: 7)
                .shadow(color: (isConnected ? palette.primary : Color.clear).opacity(0.45), radius: 5)
        }
    }

    private var compactMetrics: some View {
        VStack(alignment: .leading, spacing: 9) {
            MetricLine(label: "5H可用", value: formatAvailablePercent(fromUsed: snapshot?.fiveHourUsagePercent), palette: palette)
            MetricLine(label: "今日", value: formatToken(todayTotal), palette: palette)
            MetricLine(label: "7天日均", value: formatToken(rollingAverage), palette: palette)
            MetricLine(label: "7D可用", value: formatPercent(snapshot?.sevenDayAvailablePercent), palette: palette)
        }
    }

    private var mediumMetrics: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                MetricBox(label: "5小时可用量", value: formatAvailablePercent(fromUsed: snapshot?.fiveHourUsagePercent), detail: "剩余比例", palette: palette)
                MetricBox(label: "今日", value: formatToken(todayTotal), detail: "输入 + 输出", palette: palette)
            }
            HStack(spacing: 10) {
                MetricBox(label: "7天日均", value: formatToken(rollingAverage), detail: "最近 7 天", palette: palette)
                MetricBox(label: "7天可用量", value: formatPercent(snapshot?.sevenDayAvailablePercent), detail: "剩余比例", palette: palette)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Text(statusText)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(snapshot?.fetchError.isEmpty == false ? palette.error : palette.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        if let error = snapshot?.fetchError, !error.isEmpty {
            return "同步失败"
        }
        if let renewalText {
            return renewalText
        }
        if let value = snapshot?.lastSyncISO, !value.isEmpty {
            return "同步 \(lastSyncLabel(value))"
        }
        return "无 Codex 日志"
    }

    private var renewalText: String? {
        guard let value = snapshot?.renewalDate, let date = dateFromISO(value) else { return nil }
        let calendar = Calendar.current
        let month = calendar.component(.month, from: date)
        let day = calendar.component(.day, from: date)
        let targetDay = calendar.startOfDay(for: date)
        let today = calendar.startOfDay(for: Date())
        guard let remaining = calendar.dateComponents([.day], from: today, to: targetDay).day else {
            return "续费 \(month)/\(day)"
        }
        if remaining == 0 {
            return "续费 \(month)/\(day) · 今天"
        }
        if remaining < 0 {
            return "续费 \(month)/\(day) · 已过\(abs(remaining))天"
        }
        return "续费 \(month)/\(day) · 剩\(remaining)天"
    }
}

struct MetricLine: View {
    let label: String
    let value: String
    let palette: WidgetPalette

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(palette.muted)
            Spacer(minLength: 0)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.64)
        }
    }
}

struct MetricBox: View {
    let label: String
    let value: String
    let detail: String
    let palette: WidgetPalette

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(palette.muted)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.58)
            Text(detail)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(palette.subtle)
                .lineLimit(1)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.card.opacity(0.86), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(palette.line, lineWidth: 1)
        )
    }
}

struct WidgetPalette {
    let background: Color
    let card: Color
    let line: Color
    let primary: Color
    let text: Color
    let muted: Color
    let subtle: Color
    let error: Color

    static func named(_ name: String) -> WidgetPalette {
        switch name {
        case "mist":
            return WidgetPalette(
                background: Color(hex: 0x07110f),
                card: Color(hex: 0x10201c),
                line: Color(hex: 0x2d463e),
                primary: Color(hex: 0x8bb8a8),
                text: Color(hex: 0xe8f1ee),
                muted: Color(hex: 0xa0b3ad),
                subtle: Color(hex: 0x718780),
                error: Color(hex: 0xb88b8b)
            )
        case "laboratory":
            return WidgetPalette(
                background: Color(hex: 0x11100e),
                card: Color(hex: 0x211d17),
                line: Color(hex: 0x4b4435),
                primary: Color(hex: 0xb0a171),
                text: Color(hex: 0xf0ece2),
                muted: Color(hex: 0xb4aa91),
                subtle: Color(hex: 0x8f8878),
                error: Color(hex: 0xb88b8b)
            )
        default:
            return WidgetPalette(
                background: Color(hex: 0x080c10),
                card: Color(hex: 0x131a21),
                line: Color(hex: 0x2c3942),
                primary: Color(hex: 0x83a9b8),
                text: Color(hex: 0xe8eef2),
                muted: Color(hex: 0x9aa8b1),
                subtle: Color(hex: 0x73808a),
                error: Color(hex: 0xb88b8b)
            )
        }
    }
}

struct WidgetChrome: View {
    let palette: WidgetPalette

    var body: some View {
        ZStack {
            palette.background
            LinearGradient(
                colors: [Color.white.opacity(0.05), palette.primary.opacity(0.08), Color.black.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            GeometryReader { proxy in
                Canvas { context, size in
                    let line = palette.line
                    for x in stride(from: 0.0, through: Double(size.width), by: 24.0) {
                        var path = Path()
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x, y: size.height))
                        context.stroke(path, with: .color(line.opacity(Int(x).isMultiple(of: 72) ? 0.2 : 0.1)), lineWidth: 0.5)
                    }
                    for y in stride(from: 0.0, through: Double(size.height), by: 24.0) {
                        var path = Path()
                        path.move(to: CGPoint(x: 0, y: y))
                        path.addLine(to: CGPoint(x: size.width, y: y))
                        context.stroke(path, with: .color(line.opacity(Int(y).isMultiple(of: 72) ? 0.2 : 0.1)), lineWidth: 0.5)
                    }

                    let topLine = CGRect(x: 16, y: 14, width: max(0, proxy.size.width - 32), height: 1)
                        context.fill(Path(topLine), with: .linearGradient(
                        Gradient(colors: [.clear, palette.primary.opacity(0.46), .clear]),
                        startPoint: CGPoint(x: topLine.minX, y: topLine.midY),
                        endPoint: CGPoint(x: topLine.maxX, y: topLine.midY)
                    ))
                }
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
    let theme: String?
}

private func readSharedSnapshot() -> SharedUsageSnapshot? {
    do {
        let data = try Data(contentsOf: try sharedSnapshotURL())
        return try JSONDecoder().decode(SharedUsageSnapshot.self, from: data)
    } catch {
        return nil
    }
}

private func sharedSnapshotURL() throws -> URL {
    return realHomeDirectory()
        .appendingPathComponent("Library", isDirectory: true)
        .appendingPathComponent("Application Support", isDirectory: true)
        .appendingPathComponent("AIUsageDesklet", isDirectory: true)
        .appendingPathComponent("usage.json")
}

private func realHomeDirectory() -> URL {
    if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
    return FileManager.default.homeDirectoryForCurrentUser
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

private func parseDailyTokens(_ text: String) -> [Int] {
    let values = text
        .components(separatedBy: CharacterSet(charactersIn: "\n,， "))
        .compactMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        .filter { $0 >= 0 }

    guard values.count >= 7 else { return values }
    return Array(values.suffix(7))
}

private func formatToken(_ value: Int?) -> String {
    guard let value, value >= 0 else { return "--" }
    return formatChineseApproximation(value)
}

private func formatPercent(_ value: Double?) -> String {
    guard let value, value >= 0 else { return "--" }
    let text = percentFormatter.string(from: NSNumber(value: value)) ?? "\(Int(value.rounded()))"
    return "\(text)%"
}

private func formatAvailablePercent(fromUsed value: Double?) -> String {
    guard let value, value >= 0 else { return "--" }
    return formatPercent(max(0, min(100, 100 - value)))
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
    formatter.dateFormat = "M/d HH:mm"
    return formatter.string(from: date)
}

private func dateFromISO(_ value: String) -> Date? {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.date(from: trimmed)
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        let red = Double((hex >> 16) & 0xff) / 255.0
        let green = Double((hex >> 8) & 0xff) / 255.0
        let blue = Double(hex & 0xff) / 255.0
        self.init(.sRGB, red: red, green: green, blue: blue, opacity: opacity)
    }
}
