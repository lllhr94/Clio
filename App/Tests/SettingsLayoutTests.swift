@testable import Clio
import XCTest

@MainActor
final class SettingsLayoutTests: XCTestCase {
    func testSettingsHomeHasThreeGroupsAndTenRowsWithoutDuplicates() {
        let groups = SettingsView.groups
        XCTAssertEqual(groups.count, 3)
        let rows = groups.flatMap(\.pages)
        XCTAssertEqual(rows.count, 10)
        XCTAssertEqual(Set(rows).count, 10)
    }

    func testEveryCoreSubpageIsReachableFromHomeOrHub() {
        let home = Set(SettingsView.groups.flatMap(\.pages))
        let hubChildren = Set(SettingsView.hubChildren.values.flatMap { $0 })
        let reachable = home.union(hubChildren)

        let expected: [SettingsPage] = [
            .services, .models, .grants, .searchEngine, .connectors, .skills, .hosts,
            .companions, .memory, .timing, .theme, .size, .tone, .pet,
            .display, .context, .voice, .notifications, .privacy,
            .careBackup, .careUsage, .careStorage, .careDiagnostics,
        ]
        for page in expected {
            XCTAssertTrue(reachable.contains(page), "Expected \(page.rawValue) to stay reachable in Batch 3 settings")
        }
    }

    func testLegacyDeepLinksResolveToValidDestinations() {
        let links: [(String, SettingsPage)] = [
            ("services", .services),
            ("model", .models),
            ("capabilities", .capabilities),
            ("grants", .grants),
            ("search", .searchEngine),
            ("connectors", .connectors),
            ("skills", .skills),
            ("hosts", .hosts),
            ("companions", .companions),
            ("rooms", .rooms),
            ("memory", .memory),
            ("timing", .timing),
            ("pet", .pet),
            ("appearance", .appearance),
            ("look", .theme),
            ("look#font", .font),
            ("look#size", .size),
            ("look#tone", .tone),
            ("look#motion", .display),
            ("look#voice", .voice),
            ("voice", .voice),
            ("look#context", .context),
            ("look#notify", .notifications),
            ("look#morning", .morning),
            ("look#lock", .lock),
            ("privacy", .privacy),
            ("vault", .vault),
            ("care", .care),
            ("backup", .careBackup),
            ("usage", .careUsage),
            ("storage", .careStorage),
            ("diagnostics", .careDiagnostics),
            ("about", .about),
        ]
        for (link, expected) in links {
            XCTAssertEqual(SettingsPage(link: link), expected, "Deep link clio://settings/\(link) regressed")
        }
    }

    func testSearchFindsSubpagesBehindHubs() {
        XCTAssertTrue(SettingsView.searchPages(matching: "字体").contains(.font))
        XCTAssertTrue(SettingsView.searchPages(matching: "WebDAV").contains(.careBackup))
        XCTAssertTrue(SettingsView.searchPages(matching: "宠物").contains(.pet))
        XCTAssertTrue(SettingsView.searchPages(matching: "早报").contains(.morning))
        XCTAssertTrue(SettingsView.searchPages(matching: "联网搜索").contains(.searchEngine))
        XCTAssertTrue(SettingsView.searchPages(matching: "面容").contains(.lock))
        XCTAssertTrue(SettingsView.searchPages(matching: "密码匣").contains(.vault))
        XCTAssertTrue(SettingsView.searchPages(matching: "SSH").contains(.hosts))
    }

    func testPlusSheetAbilitiesSummaryCombinesPlaceAndOffCount() {
        XCTAssertEqual(PlusSheet.abilitiesSummaryText(placeTitle: "书案", offCount: 0), "书案 · 全开")
        XCTAssertEqual(PlusSheet.abilitiesSummaryText(placeTitle: "斗室", offCount: 2), "斗室 · 关了 2 项")
    }
}
