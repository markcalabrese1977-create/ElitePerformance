import XCTest
@testable import ElitePerformance

final class ReadinessTests: XCTestCase {
    func testLoadModifierLowStars() {
        XCTAssertEqual(Readiness.loadModifier(stars: 1), -0.10, accuracy: 0.0001)
        XCTAssertEqual(Readiness.loadModifier(stars: 2), -0.05, accuracy: 0.0001)
    }

    func testLoadModifierNeutral() {
        XCTAssertEqual(Readiness.loadModifier(stars: 3), 0.0, accuracy: 0.0001)
        XCTAssertEqual(Readiness.loadModifier(stars: 4), 0.0, accuracy: 0.0001)
    }

    func testAllowTestSet() {
        XCTAssertTrue(Readiness.allowTestSet(stars: 5))
        XCTAssertFalse(Readiness.allowTestSet(stars: 4))
    }
}
