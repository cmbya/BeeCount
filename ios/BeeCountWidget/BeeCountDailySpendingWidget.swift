import Foundation
import SwiftUI
import WidgetKit
import UIKit

extension DailySpendingSnapshot {
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
    // This personal widget is explicitly Chinese, even with no shared snapshot
    // and even when the extension process resolves Locale.current to English.
    let locale: Locale
    var title: String { "每日花销" }
    var description: String { "今日、本月支出与剩余预算，附近七天趋势" }
    var today: String { "今日已花" }
    var month: String { "本月已花" }
    var remaining: String { "还能花" }
    var week: String { "近 7 天" }
    var noBudget: String { "未设预算" }
    var refresh: String { "数据已过期，请打开 App 刷新" }
    var weekdays: [String] { ["一", "二", "三", "四", "五", "六", "日"] }
}

private struct DailySpendingEntry: TimelineEntry {
    let date: Date
    let snapshot: DailySpendingSnapshot?
    var message: String? = nil
}

private struct DailySpendingProvider: TimelineProvider {
    private func runtimeEntry(at date: Date) -> DailySpendingEntry {
        do {
            let snapshot = try DailySpendingSharedStore.read()
            return DailySpendingEntry(date: date, snapshot: snapshot)
        } catch let error as DailySpendingStorageError {
            return DailySpendingEntry(date: date, snapshot: nil, message: error.message)
        } catch {
            return DailySpendingEntry(date: date, snapshot: nil, message: "共享数据读取失败，请到 App 检查")
        }
    }

    func placeholder(in context: Context) -> DailySpendingEntry {
        let now = Date()
        return DailySpendingEntry(date: now, snapshot: .preview(at: now))
    }

    func getSnapshot(in context: Context, completion: @escaping (DailySpendingEntry) -> Void) {
        let now = Date()
        completion(context.isPreview ? DailySpendingEntry(date: now, snapshot: .preview(at: now)) : runtimeEntry(at: now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<DailySpendingEntry>) -> Void) {
        let now = Date()
        let entry = runtimeEntry(at: now)
        let snapshot = entry.snapshot
        var entries = [entry]
        let calendar = Calendar.current
        let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now.addingTimeInterval(86400)
        // Pre-schedule a stale state at midnight. A timeline reload only reads
        // the shared snapshot; it cannot wake Flutter to recompute the amounts.
        entries.append(DailySpendingEntry(date: midnight, snapshot: snapshot, message: entry.message))
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
        formatter.locale = Locale(identifier: "zh_CN")
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
                }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
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
                }.buttonStyle(.plain).frame(maxWidth: .infinity, alignment: .leading)
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
                        Text(entry.message ?? copy.refresh).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
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
