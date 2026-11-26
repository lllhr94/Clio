@testable import Craft
import Foundation
import XCTest

final class LogicalDayTests: XCTestCase {
    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int,
        minute: Int = 0,
        timeZone: TimeZone
    ) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        return cal.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    func testBoundaryAt0400SplitsPreviousAndCurrentDay() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let beforeBoundary = makeDate(year: 2026, month: 11, day: 27, hour: 3, minute: 59, timeZone: tz)
        let atBoundary = makeDate(year: 2026, month: 11, day: 27, hour: 4, minute: 0, timeZone: tz)

        XCTAssertEqual(LogicalDay.day(of: beforeBoundary, calendar: cal), "2026-11-26")
        XCTAssertEqual(LogicalDay.day(of: atBoundary, calendar: cal), "2026-11-27")
    }

    func testDSTSpringForwardAndFallBackTransitionsStayAccurate() {
        let nyTZ = TimeZone(identifier: "America/New_York")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = nyTZ

        // Spring forward in NYC: 2026-03-08 02:00 jumps to 03:00 (23-hour day).
        // Previous logical day still belongs to 2026-03-07 at 03:30, and 04:00 rolls to 2026-03-08.
        let springPre = makeDate(year: 2026, month: 3, day: 8, hour: 3, minute: 30, timeZone: nyTZ)
        let springPost = makeDate(year: 2026, month: 3, day: 8, hour: 4, minute: 5, timeZone: nyTZ)
        XCTAssertEqual(LogicalDay.day(of: springPre, calendar: cal), "2026-03-07")
        XCTAssertEqual(LogicalDay.day(of: springPost, calendar: cal), "2026-03-08")
        XCTAssertEqual(LogicalDay.daysBack(1, from: springPost, calendar: cal), "2026-03-07")

        // Fall back in NYC: 2026-11-01 02:00 repeats (25-hour day).
        let fallPre = makeDate(year: 2026, month: 11, day: 1, hour: 3, minute: 45, timeZone: nyTZ)
        let fallPost = makeDate(year: 2026, month: 11, day: 1, hour: 4, minute: 0, timeZone: nyTZ)
        XCTAssertEqual(LogicalDay.day(of: fallPre, calendar: cal), "2026-10-31")
        XCTAssertEqual(LogicalDay.day(of: fallPost, calendar: cal), "2026-11-01")
        XCTAssertEqual(LogicalDay.daysBack(1, from: fallPost, calendar: cal), "2026-10-31")
    }

    func testNightlyReviewDayConsistencyAcrossMidnightAnd0400() {
        let tz = TimeZone(identifier: "Asia/Shanghai")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz

        let lateEvening = makeDate(year: 2026, month: 11, day: 26, hour: 23, minute: 30, timeZone: tz)
        let earlyAMBefore4 = makeDate(year: 2026, month: 11, day: 27, hour: 3, minute: 59, timeZone: tz)
        let earlyAMAfter4 = makeDate(year: 2026, month: 11, day: 27, hour: 4, minute: 30, timeZone: tz)
        let daytime = makeDate(year: 2026, month: 11, day: 27, hour: 12, minute: 0, timeZone: tz)

        XCTAssertEqual(LogicalDay.nightlyReviewDay(at: lateEvening, catchUp: false, calendar: cal), "2026-11-26")
        XCTAssertEqual(LogicalDay.nightlyReviewDay(at: earlyAMBefore4, catchUp: false, calendar: cal), "2026-11-26")
        XCTAssertEqual(LogicalDay.nightlyReviewDay(at: earlyAMAfter4, catchUp: false, calendar: cal), "2026-11-26")
        XCTAssertNil(LogicalDay.nightlyReviewDay(at: daytime, catchUp: false, calendar: cal))
        XCTAssertEqual(LogicalDay.nightlyReviewDay(at: daytime, catchUp: true, calendar: cal), "2026-11-26")
    }

    func testNormalizeLegacyDayKey() {
        XCTAssertEqual(LogicalDay.normalizeLegacyDayKey("2026/3/5"), "2026-03-05")
        XCTAssertEqual(LogicalDay.normalizeLegacyDayKey(" 2026-11-27 "), "2026-11-27")
        XCTAssertNil(LogicalDay.normalizeLegacyDayKey("invalid"))
        XCTAssertNil(LogicalDay.normalizeLegacyDayKey(""))
    }
}
