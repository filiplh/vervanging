import XCTest

/// The app starts and shows its first screen, Spelers (#100).
final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsTheFirstScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
    }
}
