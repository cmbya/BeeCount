import Foundation
import XCTest
@testable import Runner

final class DailySpendingSharedStoreTests: XCTestCase {
    private func candidate(_ id: String, selected: Bool = false) -> DailySpendingSharedStore.Candidate {
        .init(id: id, url: URL(fileURLWithPath: "/test/" + id), selected: selected, hasSnapshot: false)
    }

    func testGroupSelectionDoesNotPickArbitraryGroup() throws {
        XCTAssertThrowsError(try DailySpendingSharedStore.select([])) {
            XCTAssertEqual(($0 as? DailySpendingStorageError)?.rawValue, "noAccess")
        }
        XCTAssertThrowsError(try DailySpendingSharedStore.select([candidate("group.a"), candidate("group.b")])) {
            XCTAssertEqual(($0 as? DailySpendingStorageError)?.rawValue, "chooseGroup")
        }
        XCTAssertEqual(try DailySpendingSharedStore.select([candidate("group.resigned")]).id, "group.resigned")
        XCTAssertEqual(try DailySpendingSharedStore.select([
            candidate("group.other"), candidate(DailySpendingSharedStore.defaultGroup)]).id, DailySpendingSharedStore.defaultGroup)
        XCTAssertEqual(try DailySpendingSharedStore.select([
            candidate(DailySpendingSharedStore.defaultGroup), candidate("group.selected", selected: true)]).id, "group.selected")
        XCTAssertThrowsError(try DailySpendingSharedStore.select([
            candidate("group.a", selected: true), candidate("group.b", selected: true)]))
    }

    func testProfilesAreOnlyCandidateIDsAndWildcardsAreRejected() throws {
        let bytes = try PropertyListSerialization.data(fromPropertyList: ["Entitlements": [
            "com.apple.security.application-groups": ["group.valid", "group.*", "invalid"]
        ]], format: .xml, options: 0)
        XCTAssertEqual(DailySpendingSharedStore.profileGroups(bytes), ["group.valid"])
        XCTAssertTrue(DailySpendingSharedStore.profileGroups(Data("broken".utf8)).isEmpty)
    }

    func testDateValidityAndOverspendingArePreserved() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 8 * 3600))
        let now = Date(timeIntervalSince1970: 1794189600)
        let start = calendar.startOfDay(for: now)
        let end = try XCTUnwrap(calendar.date(byAdding: .day, value: 1, to: start))
        let days = (0..<7).map { index in
            DailySpendingDay(date: "day-\(index)", weekday: index + 1, total: Double(index))
        }
        let snapshot = DailySpendingSnapshot(schemaVersion: 1, ledgerId: 1, currency: "CNY",
            currencySymbol: "¥", locale: "zh_CN", generatedAtMs: now.timeIntervalSince1970 * 1000,
            dayStartMs: start.timeIntervalSince1970 * 1000, dayEndMs: end.timeIntervalSince1970 * 1000,
            periodStartMs: start.timeIntervalSince1970 * 1000,
            periodEndMs: end.timeIntervalSince1970 * 1000,
            todayExpense: 10, monthExpense: 20, budgetRemaining: -5, days: days)
        XCTAssertTrue(snapshot.valid)
        XCTAssertTrue(snapshot.isCurrent(at: now, calendar: calendar))
        XCTAssertFalse(snapshot.isCurrent(at: end, calendar: calendar))
        let decoded = try JSONDecoder().decode(DailySpendingSnapshot.self, from: JSONEncoder().encode(snapshot))
        XCTAssertEqual(decoded.budgetRemaining, -5)
        XCTAssertEqual(decoded.days.count, 7)
    }
}
