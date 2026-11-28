@testable import Clio
import Foundation
import XCTest

@MainActor
final class SharedFrameDriverTests: XCTestCase {
    func testInactiveSubscriptionLeavesClockIdleUntilVisibilityWakesIt() {
        let driver = SharedFrameDriver(isInForeground: true) { self.budget(.nominal) }
        var visible = false
        var count = 0
        XCTAssertEqual(driver.activeMaxFPS, 0)

        let link = driver.add(rate: .max, isActive: { visible }) { _ in count += 1 }
        XCTAssertEqual(driver.activeMaxFPS, 0)
        visible = true
        driver.requestArbitrationUpdate()
        XCTAssertEqual(driver.activeMaxFPS, 120)
        driver.tick(timestamp: 10, targetTimestamp: 10 + 1.0 / 120)
        XCTAssertEqual(count, 1)

        visible = false
        driver.tick(timestamp: 10 + 1.0 / 120, targetTimestamp: 10 + 2.0 / 120)
        XCTAssertEqual(driver.activeMaxFPS, 0)
        XCTAssertNil(driver.lastTargetTimestamp)
        XCTAssertEqual(count, 1)
        link.invalidate()
    }

    func testHiddenHighRateSubscriptionLowersCadenceOfRemainingClock() {
        let driver = SharedFrameDriver(isInForeground: true) { self.budget(.nominal) }
        var visible = true
        let fast = driver.add(rate: .max, isActive: { visible }) { _ in }
        let slow = driver.add(rate: .fps(12)) { _ in }
        XCTAssertEqual(driver.activeMaxFPS, 120)

        visible = false
        driver.tick(timestamp: 10, targetTimestamp: 10 + 1.0 / 120)
        XCTAssertEqual(driver.activeMaxFPS, 12)
        slow.isPaused = true
        XCTAssertEqual(driver.activeMaxFPS, 0)
        visible = true
        driver.requestArbitrationUpdate()
        XCTAssertEqual(driver.activeMaxFPS, 120)
        fast.invalidate()
        XCTAssertEqual(driver.activeMaxFPS, 0)
    }

    func testFixedCadenceUsesElapsedFrameTimeBesideAHighRateClient() {
        let driver = SharedFrameDriver(isInForeground: true) { self.budget(.serious) }
        var fastTicks = 0
        var slowTicks = 0
        let fast = driver.add(rate: .max) { _ in fastTicks += 1 }
        let slow = driver.add(rate: .fps(12)) { _ in slowTicks += 1 }
        XCTAssertEqual(driver.activeMaxFPS, 60)
        for frame in 0..<120 {
            driver.tick(timestamp: 10 + Double(frame) / 60, targetTimestamp: 10 + Double(frame + 1) / 60)
        }
        XCTAssertEqual(fastTicks, 120)
        XCTAssertEqual(slowTicks, 24)
        fast.invalidate()
        slow.invalidate()
    }

    func testFixedCadenceHoldsWhenTheSystemDeliversFasterThanRequested() {
        let driver = SharedFrameDriver(isInForeground: true) { self.budget(.nominal) }
        var ticks = 0
        let link = driver.add(rate: .fps(12)) { _ in ticks += 1 }
        XCTAssertEqual(driver.activeMaxFPS, 12)
        for frame in 0..<60 {
            driver.tick(timestamp: 10 + Double(frame) / 60, targetTimestamp: 10 + Double(frame + 1) / 60)
        }
        XCTAssertEqual(ticks, 12)
        link.invalidate()
    }

    func testLastLinkReleasedAndInvalidationInsideCallbackBothStopClock() {
        let driver = SharedFrameDriver(isInForeground: true) { self.budget(.nominal) }
        var released: SharedFrameLink? = driver.add(rate: .max) { _ in XCTFail("Released link delivered a frame") }
        XCTAssertNotNil(released)
        released = nil
        driver.tick(timestamp: 10, targetTimestamp: 10 + 1.0 / 120)
        XCTAssertEqual(driver.activeMaxFPS, 0)

        weak var callbackLink: SharedFrameLink?
        let link = driver.add(rate: .max) { _ in callbackLink?.invalidate() }
        callbackLink = link
        driver.tick(timestamp: 11, targetTimestamp: 11 + 1.0 / 120)
        XCTAssertEqual(driver.activeMaxFPS, 0)
    }

    func testRuntimeBudgetTiersAndOverrides() {
        let nominal = budget(.nominal)
        XCTAssertEqual(nominal.tier, .full)
        XCTAssertEqual(nominal.maxPreferredFPS, 120)
        XCTAssertTrue(nominal.allowsRevealSnippets)
        XCTAssertTrue(nominal.allowsContinuousGlassEffects)
        XCTAssertEqual(nominal.petIdleFPS, 12)
        XCTAssertEqual(budget(.fair), nominal)

        let conserve = budget(.serious)
        XCTAssertEqual(conserve.tier, .conserve)
        XCTAssertEqual(conserve.maxPreferredFPS, 60)
        XCTAssertFalse(conserve.allowsRevealSnippets)
        XCTAssertEqual(conserve.petIdleFPS, 4)
        XCTAssertEqual(budget(.nominal, lowPower: true), conserve)

        let critical = budget(.critical, lowPower: true)
        XCTAssertEqual(critical.tier, .critical)
        XCTAssertEqual(critical.maxPreferredFPS, 30)
        XCTAssertFalse(critical.allowsContinuousGlassEffects)
        XCTAssertLessThan(critical.prefetchWindowScale, conserve.prefetchWindowScale)
        XCTAssertEqual(budget(.nominal, reduceMotion: true).maxPreferredFPS, 60)
        XCTAssertEqual(budget(.nominal, reduceVisualEffects: true).tier, .critical)
    }

    private func budget(
        _ thermalState: ProcessInfo.ThermalState,
        lowPower: Bool = false,
        reduceMotion: Bool = false,
        reduceVisualEffects: Bool = false
    ) -> RuntimeBudgetSnapshot {
        RuntimeBudgetPolicy.evaluate(thermalState: thermalState, isLowPowerMode: lowPower,
                                     reduceMotion: reduceMotion, reduceVisualEffects: reduceVisualEffects)
    }
}
