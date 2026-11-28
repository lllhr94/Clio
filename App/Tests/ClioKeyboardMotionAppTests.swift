@testable import Clio
import UIKit
import XCTest

final class ClioKeyboardMotionAppTests: XCTestCase {
    func testStandardKeyboardNotificationUsesMeasuredSpring() {
        let motion = makeMotion(duration: 0.38, curve: 7)
        let spring = motion.spring.parameters
        XCTAssertEqual(motion.duration, 0.3832, accuracy: 0.0001)
        XCTAssertNil(motion.curve)
        XCTAssertEqual(spring.mass, 1)
        XCTAssertEqual(spring.stiffness, 555.027, accuracy: 0.001)
        XCTAssertEqual(spring.damping, 47.118, accuracy: 0.001)
        XCTAssertNotNil(motion.swiftUIAnimation)
    }

    func testImmediateKeyboardNotificationDoesNotInventAnAnimation() {
        let motion = makeMotion(duration: 0, curve: 7)
        XCTAssertEqual(motion.duration, 0)
        XCTAssertNil(motion.swiftUIAnimation)
    }

    func testOtherKeyboardNotificationsKeepTheirReportedTiming() {
        let motion = makeMotion(duration: 0.22, curve: UIView.AnimationCurve.linear.rawValue)
        XCTAssertEqual(motion.duration, 0.22, accuracy: 0.0001)
        XCTAssertEqual(motion.curve, .linear)
        XCTAssertNotNil(motion.swiftUIAnimation)
    }

    private func makeMotion(duration: Double, curve: Int) -> ClioKeyboardMotion {
        ClioKeyboardMotion(Notification(
            name: UIResponder.keyboardWillChangeFrameNotification,
            userInfo: [
                UIResponder.keyboardAnimationDurationUserInfoKey: duration,
                UIResponder.keyboardAnimationCurveUserInfoKey: curve
            ]
        ))
    }
}
