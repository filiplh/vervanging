import XCTest

/// The app starts and shows its first screen, titled "Vervanging".
final class LaunchTests: XCTestCase {
    override func setUp() {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsTheFirstScreen() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.navigationBars["Vervanging"].waitForExistence(timeout: 10))
    }
}
