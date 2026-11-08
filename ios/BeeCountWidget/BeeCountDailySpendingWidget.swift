import Foundation
import SwiftUI
import WidgetKit
import UIKit

private struct DailySpendingDay: Decodable {
    let date: String
    let weekday: Int
    let total: Double
}

private struct DailySpendingSnapshot: Decodable {
    let schemaVersion: Int
    let ledgerId: Int
    let currency: String
    let currencySymbol: String
    let locale: String
    let generatedAtMs: Double
    let dayStartMs: Double
    let dayEndMs: Double
    let periodStartMs: Double
    let periodEndMs: Double
    let todayExpense: Double
    let monthExpense: Double
    let budgetRemaining: Double?
    let days: [DailySpendingDay]

    func isCurrent(at date: Date) -> Bool {
        let ms = date.timeIntervalSince1970 * 1000
        // Also invalidate after a timezone change that changes the local day.
        let localStart = Calendar.current.startOfDay(for: date).timeIntervalSince1970 * 1000
        return schemaVersion == 1 && days.count == 7 &&
            abs(localStart - dayStartMs) < 1000 &&
            ms >= dayStartMs && ms < dayEndMs &&
            ms >= periodStartMs && ms < periodEndMs &&
            generatedAtMs >= dayStartMs && generatedAtMs < dayEndMs
    }

    static func preview(at date: Date) -> DailySpendingSnapshot? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start),
              let period = calendar.dateInterval(of: .month, for: date) else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let values: [Double] = [36, 12, 280, 0, 65, 42, 128.5]
        let days = values.enumerated().compactMap { index, value -> DailySpendingDay? in
            guard let day = calendar.date(byAdding: .day, value: index - 6, to: start) else { return nil }
            let weekday = (calendar.component(.weekday, from: day) + 5) % 7 + 1
            return DailySpendingDay(date: formatter.string(from: day), weekday: weekday, total: value)
        }
        return DailySpendingSnapshot(
            schemaVersion: 1, ledgerId: 0, currency: "CNY", currencySymbol: "¥",
            locale: Locale.current.identifier, generatedAtMs: date.timeIntervalSince1970 * 1000,
            dayStartMs: start.timeIntervalSince1970 * 1000, dayEndMs: end.timeIntervalSince1970 * 1000,
            periodStartMs: period.start.timeIntervalSince1970 * 1000,
            periodEndMs: period.end.timeIntervalSince1970 * 1000,
            todayExpense: 128.5, monthExpense: 3524, budgetRemaining: 1686, days: days
        )
    }
}

private struct DailySpendingCopy {
    let locale: Locale
    private var language: String { locale.languageCode ?? "en" }
    private var traditional: Bool {
        locale.scriptCode == "Hant" || ["TW", "HK", "MO"].contains(locale.regionCode ?? "")
    }
    private func text(_ simplified: String, _ traditional: String, _ english: String, _ korean: String) -> String {
        switch language {
        case "zh": return self.traditional ? traditional : simplified
        case "ko": return korean
        default: return english
        }
    }
    var title: String { text("每日花销", "每日花銷", "Daily Spending", "매일 지출") }
    var description: String {
        text("今日、本月支出与剩余预算，附近七天趋势", "今日、本月支出與剩餘預算，附近七天趨勢",
             "Today's spending, this month's spending, remaining budget and a seven-day trend", "오늘과 이번 달 지출, 남은 예산 및 최근 7일 추이")
    }
    var today: String { text("今日已花", "今日已花", "Spent today", "오늘 지출") }
    var month: String { text("本月已花", "本月已花", "This month", "이번 달 지출") }
    var remaining: String { text("还能花", "還能花", "Budget left", "남은 예산") }
    var week: String { text("近 7 天", "近 7 天", "Last 7 days", "최근 7일") }
    var noBudget: String { text("未设预算", "未設預算", "Not set", "미설정") }
    var refresh: String { text("打开 App 更新", "開啟 App 更新", "Open app to update", "앱을 열어 업데이트") }
    var weekdays: [String] {
        switch language {
        case "zh": return ["一", "二", "三", "四", "五", "六", "日"]
        case "ko": return ["월", "화", "수", "목", "금", "토", "일"]
        default: return ["M", "T", "W", "T", "F", "S", "S"]
        }
    }
}

private struct DailySpendingEntry: TimelineEntry {
    let date: Date
    let snapshot: DailySpendingSnapshot?
}

private struct DailySpendingProvider: TimelineProvider {
    private func readSnapshot() -> DailySpendingSnapshot? {
        guard let raw = UserDefaults(suiteName: "group.com.tntlikely.beecount")?
            .string(forKey: "widget_daily_spending_v1"),
              let data = raw.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(DailySpendingSnapshot.self, from: data),
              snapshot.schemaVersion == 1,
              snapshot.days.count == 7,
              snapshot.days.allSatisfy({ (1...7).contains($0.weekday) && $0.total.isFinite }),
              snapshot.todayExpense.isFinite, snapshot.monthExpense.isFinite,
              snapshot.budgetRemaining?.isFinite != false else { return nil }
        return snapshot
    }

    func placeholder(in context: Context) -> DailySpendingEntry {
        let now = Date()
        return DailySpendingEntry(date: now, snapshot: .preview(at: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (DailySpendingEntry) -> Void) {
        let now = Date()
        completion(DailySpendingEntry(date: now, snapshot: context.isPreview ? .preview(at: now) : readSnapshot()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailySpendingEntry>) -> Void) {
        let now = Date()
        let snapshot = readSnapshot()
        var entries = [DailySpendingEntry(date: now, snapshot: snapshot)]
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        // Pre-schedule a stale state at midnight. A timeline reload only reads
        // the shared snapshot; it cannot wake Flutter to recompute the amounts.
        entries.append(DailySpendingEntry(date: midnight, snapshot: snapshot))
        let next = min(midnight, now.addingTimeInterval(30 * 60))
        completion(Timeline(entries: entries, policy: .after(next)))
    }
}

private struct DailySpendingEntryView: View {
    let entry: DailySpendingEntry
    private let detailURL = URL(string: "beecount://open?page=detail")!
    private let budgetURL = URL(string: "beecount://open?page=budget")!
    private let statisticsURL = URL(string: "beecount://open?page=statistics")!
    private var copy: DailySpendingCopy {
        DailySpendingCopy(locale: entry.snapshot.map { Locale(identifier: $0.locale) } ?? .current)
    }
    private var current: DailySpendingSnapshot? {
        guard let snapshot = entry.snapshot, snapshot.isCurrent(at: entry.date) else { return nil }
        return snapshot
    }

    private func money(_ value: Double, snapshot: DailySpendingSnapshot) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: snapshot.locale)
        formatter.numberStyle = .currency
        formatter.currencyCode = snapshot.currency
        formatter.currencySymbol = snapshot.currencySymbol
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? "\(snapshot.currencySymbol)\(value)"
    }

    private func amount(_ text: String, size: CGFloat, color: Color = .primary) -> some View {
        Text(text).font(.system(size: size, weight: .semibold, design: .rounded))
            .monospacedDigit().foregroundColor(color).lineLimit(1).minimumScaleFactor(0.45)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .medium)).foregroundColor(.secondary)
            .lineLimit(1).minimumScaleFactor(0.7)
    }

    private func summary(_ snapshot: DailySpendingSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Link(destination: detailURL) {
                VStack(alignment: .leading, spacing: 3) {
                    caption(copy.today)
                    amount(snapshot.map { money($0.todayExpense, snapshot: $0) } ?? "—", size: 36)
                }
            }.buttonStyle(.plain)
            Spacer(minLength: 8)
            HStack(alignment: .top, spacing: 10) {
                Link(destination: detailURL) {
                    VStack(alignment: .leading, spacing: 4) {
                        amount(snapshot.map { money($0.monthExpense, snapshot: $0) } ?? "—", size: 16)
                        caption(copy.month)
                    }
                }.buttonStyle(.plain)
                Link(destination: budgetURL) {
                    VStack(alignment: .leading, spacing: 4) {
                        if let snapshot = snapshot {
                            if let remaining = snapshot.budgetRemaining {
                                amount(money(remaining, snapshot: snapshot), size: 16, color: remaining < 0 ? .red : .primary)
                            } else {
                                amount(copy.noBudget, size: 13, color: .secondary)
                            }
                        } else {
                            amount("—", size: 16)
                        }
                        caption(copy.remaining)
                    }
                }.buttonStyle(.plain)
            }
        }
    }

    private func chart(_ snapshot: DailySpendingSnapshot) -> some View {
        let maximum = max(1, snapshot.days.map { max(0, $0.total) }.max() ?? 0)
        return VStack(alignment: .leading, spacing: 6) {
            caption(copy.week)
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array(snapshot.days.enumerated()), id: \.offset) { index, day in
                        VStack(spacing: 5) {
                            Spacer(minLength: 0)
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .fill(day.total > 0 ? Color.blue.opacity(index == 6 ? 0.9 : 0.65) : Color.secondary.opacity(0.2))
                                .frame(height: max(2, CGFloat(max(0, day.total) / maximum) * max(0, geometry.size.height - 22)))
                            Text(copy.weekdays[day.weekday - 1])
                                .font(.system(size: 10, weight: index == 6 ? .semibold : .regular))
                                .foregroundColor(index == 6 ? .primary : .secondary)
                                .frame(height: 14)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(day.date), \(money(day.total, snapshot: snapshot))")
                    }
                }
            }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let snapshot = current
            HStack(alignment: .top, spacing: 16) {
                summary(snapshot).frame(width: max(0, (geometry.size.width - 48) * 0.52))
                if let snapshot = snapshot {
                    Link(destination: statisticsURL) { chart(snapshot) }.buttonStyle(.plain)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        caption(copy.week)
                        Spacer(minLength: 0)
                        Image(systemName: "arrow.clockwise").font(.system(size: 22)).foregroundColor(.secondary)
                        Text(copy.refresh).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(16)
        }
        .background(Color(UIColor.secondarySystemBackground))
        .widgetURL(detailURL)
        .privacySensitive()
    }
}

struct BeeCountDailySpendingWidget: Widget {
    let kind = "BeeCountDailySpendingWidget"

    var body: some WidgetConfiguration {
        let copy = DailySpendingCopy(locale: .current)
        return StaticConfiguration(kind: kind, provider: DailySpendingProvider()) { entry in
            if #available(iOS 17.0, *) {
                DailySpendingEntryView(entry: entry)
                    .containerBackground(for: .widget) { Color(UIColor.secondarySystemBackground) }
            } else {
                DailySpendingEntryView(entry: entry)
            }
        }
        .configurationDisplayName(copy.title)
        .description(copy.description)
        .supportedFamilies([.systemMedium])
        .contentMarginsDisabled()
    }
}
