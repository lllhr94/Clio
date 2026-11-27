import AgentKit
@testable import Clio
import Craft
import Foundation
import XCTest

final class ClioAppPR1CTests: XCTestCase {
    func testBuiltInSkillsRegisteredToggleableAndIsolatedOnCasualTrack() async throws {
        let all = SkillShelf.all(fresh: true)
        let quietMusing = try XCTUnwrap(all.first(where: { $0.skill.name == "quiet-musing" }))
        let userGuide = try XCTUnwrap(all.first(where: { $0.skill.name == "user-guide" }))
        XCTAssertTrue(quietMusing.isBuiltIn)
        XCTAssertTrue(userGuide.isBuiltIn)

        let wasQuietOn = quietMusing.on
        let wasGuideOn = userGuide.on
        defer {
            SkillShelf.setOn(quietMusing, wasQuietOn)
            SkillShelf.setOn(userGuide, wasGuideOn)
        }

        SkillShelf.setOn(quietMusing, false)
        XCTAssertFalse(SkillShelf.enabled.contains(where: { $0.id == quietMusing.id }))

        SkillShelf.setOn(quietMusing, true)
        SkillShelf.setOn(userGuide, true)
        XCTAssertTrue(SkillShelf.enabled.contains(where: { $0.id == quietMusing.id }))

        XCTAssertEqual(SkillShelf.promptBlock(casualTrack: true), "")
        XCTAssertTrue(SkillShelf.promptBlock(casualTrack: false).contains("quiet-musing"))
        XCTAssertTrue(SkillShelf.promptBlock(casualTrack: false).contains("user-guide"))

        let output = try await UseSkillTool().run(["name": .string("quiet-musing")])
        XCTAssertFalse(output.isError)
        XCTAssertTrue(output.content.contains("quiet-musing"))
    }

    func testCPUGuardEvaluatorRequiresSustainedHighUtilizationAndCooldown() {
        var evaluator = CPUGuard.Evaluator(thresholdUtilization: 1.5, sustainedDuration: 15, cooldownDuration: 300)
        let t0 = Date(timeIntervalSince1970: 1_000)

        // First high sample records start of window, no warning yet.
        XCTAssertNil(evaluator.evaluate(cpuSecondsDelta: 10, wallSecondsDelta: 5, at: t0))
        // Sustained 10s (< 15s), no warning yet.
        XCTAssertNil(evaluator.evaluate(cpuSecondsDelta: 10, wallSecondsDelta: 5, at: t0.addingTimeInterval(10)))
        // Sustained 16s (>= 15s) triggers warning once.
        let warning = evaluator.evaluate(cpuSecondsDelta: 12, wallSecondsDelta: 6, at: t0.addingTimeInterval(16))
        XCTAssertNotNil(warning)

        // Cooldown suppresses repeat warning at 60s.
        XCTAssertNil(evaluator.evaluate(cpuSecondsDelta: 10, wallSecondsDelta: 5, at: t0.addingTimeInterval(60)))

        // Dropping below threshold resets the high-utilization streak.
        XCTAssertNil(evaluator.evaluate(cpuSecondsDelta: 1, wallSecondsDelta: 5, at: t0.addingTimeInterval(70)))
    }

    @MainActor
    func testDenDNSPrefsPersistUnderChatPrefixAndPreserveValidResolvConf() throws {
        let suiteName = "clio-pr1c-dns-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-den-dns-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolvURL = dir.appendingPathComponent("resolv.conf", isDirectory: false)

        let parsed = Den.shared.updateDNSConfiguration(mode: .custom, customInput: "10.0.0.53, bad-host", defaults: defaults, resolvURL: resolvURL)
        XCTAssertEqual(parsed.valid, ["10.0.0.53"])
        XCTAssertEqual(parsed.invalid, ["bad-host"])
        XCTAssertEqual(defaults.string(forKey: Den.dnsModeDefaultsKey), DenDNSMode.custom.rawValue)
        XCTAssertEqual(defaults.string(forKey: Den.customDNSDefaultsKey), "10.0.0.53")

        let customOutcome = Den.writeResolvConfNow(
            mode: .custom,
            customServers: parsed.valid,
            resolvURL: resolvURL,
            systemServersOverride: ["192.168.1.1"],
            searchDomainsOverride: ["lan"]
        )
        XCTAssertTrue(customOutcome.wrote)
        let savedText = try String(contentsOf: resolvURL, encoding: .utf8)
        XCTAssertTrue(savedText.contains("nameserver 10.0.0.53"))

        // Auto mode with empty transient system DNS preserves valid resolv.conf rather than writing public DNS.
        let autoPreserve = Den.writeResolvConfNow(
            mode: .auto,
            customServers: [],
            resolvURL: resolvURL,
            systemServersOverride: [],
            searchDomainsOverride: []
        )
        XCTAssertFalse(autoPreserve.wrote)
        XCTAssertEqual(try String(contentsOf: resolvURL, encoding: .utf8), savedText)
    }

    func testDenIdleOnlyTempCleanupGuard() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("clio-den-clean-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let home = root.appendingPathComponent("Den", isDirectory: true)
        let alpineTmp = home.appendingPathComponent("alpine/data/tmp", isDirectory: true)
        let hostTmp = root.appendingPathComponent("HostTmp", isDirectory: true)
        try FileManager.default.createDirectory(at: alpineTmp, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hostTmp, withIntermediateDirectories: true)

        let staleTmpFile = alpineTmp.appendingPathComponent("build.tmp")
        let staleSock = hostTmp.appendingPathComponent("densock.123")
        let unrelatedSock = hostTmp.appendingPathComponent("other.tmp")
        try Data(repeating: 0x41, count: 128).write(to: staleTmpFile)
        try Data(repeating: 0x42, count: 64).write(to: staleSock)
        try Data(repeating: 0x43, count: 32).write(to: unrelatedSock)

        XCTAssertEqual(Den.managedTempBytes(home: home, tempDirectory: hostTmp), 192)

        // Must refuse cleanup while Den has running PIDs.
        let busyOutcome = await Den.cleanHostTempFiles(runningPIDs: [42], home: home, tempDirectory: hostTmp)
        XCTAssertTrue(busyOutcome.skippedBecauseBusy)
        XCTAssertEqual(busyOutcome.freedBytes, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleTmpFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: staleSock.path))

        // Succeeds cleanly once idle, while leaving non-Den files untouched.
        let idleOutcome = await Den.cleanHostTempFiles(runningPIDs: [], home: home, tempDirectory: hostTmp)
        XCTAssertFalse(idleOutcome.skippedBecauseBusy)
        XCTAssertEqual(idleOutcome.freedBytes, 192)
        XCTAssertEqual(idleOutcome.removedCount, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleTmpFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: staleSock.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: unrelatedSock.path))
        XCTAssertEqual(Den.managedTempBytes(home: home, tempDirectory: hostTmp), 0)
    }
}
