import XCTest
@testable import ElitePerformance

final class ProgressionTests: XCTestCase {
    func testIncreaseWhenAllSetsAtTop() {
        let decision = Progression.decideAdjustment(actualReps: [12,12,12], targetUpper: 12, repDrop: 0)
        switch decision {
        case .increase(let pct):
            XCTAssertEqual(pct, 0.05, accuracy: 0.0001)
        default:
            XCTFail("Expected increase")
        }
    }

    func testDecreaseOnMajorDrop() {
        let decision = Progression.decideAdjustment(actualReps: [8,6,5], targetUpper: 12, repDrop: 2)
        switch decision {
        case .decrease(let pct):
            XCTAssertEqual(pct, 0.05, accuracy: 0.0001)
        default:
            XCTFail("Expected decrease")
        }
    }

    func testHoldOtherwise() {
        let decision = Progression.decideAdjustment(actualReps: [10,10,9], targetUpper: 12, repDrop: 1)
        switch decision {
        case .hold:
            XCTAssertTrue(true)
        default:
            XCTFail("Expected hold")
        }
    }
}
