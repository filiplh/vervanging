import SwiftUI
import Testing
import UIKit
@testable import Vervanging

/// The on-court cells in the live screen's minutes at a glance (#167): white text on the `OnCourtFill` colour set
/// reaches WCAG's 4.5:1 for text in light and dark mode, with and without Increase Contrast. The system tint gave 3.5:1
/// in light mode.
@MainActor
struct LiveColourTests {
    nonisolated static let variants: [(String, UIUserInterfaceStyle, UIAccessibilityContrast)] = [
        ("light", .light, .normal),
        ("dark", .dark, .normal),
        ("light, Increase Contrast", .light, .high),
        ("dark, Increase Contrast", .dark, .high),
    ]

    @Test(arguments: variants.indices)
    func onCourtTextOnFillReachesFourPointFiveToOne(_ index: Int) throws {
        let (name, style, contrast) = Self.variants[index]
        let traits = UITraitCollection { traits in
            traits.userInterfaceStyle = style
            traits.accessibilityContrast = contrast
        }
        let fill = try #require(UIColor(named: OnCourtCell.fillName, in: .main, compatibleWith: traits),
                                "the colour set is in the app")
        let text = UIColor(OnCourtCell.text).resolvedColor(with: traits)
        let ratio = Self.contrast(text, fill.resolvedColor(with: traits))
        #expect(ratio >= 4.5, "\(name): \(ratio):1")
    }

    @Test func theIncreaseContrastVariantsDifferFromThePlainOnes() throws {
        func fill(_ style: UIUserInterfaceStyle, _ contrast: UIAccessibilityContrast) throws -> [CGFloat] {
            let traits = UITraitCollection { $0.userInterfaceStyle = style; $0.accessibilityContrast = contrast }
            let color = try #require(UIColor(named: OnCourtCell.fillName, in: .main, compatibleWith: traits))
            return Self.components(color.resolvedColor(with: traits))
        }
        #expect(try fill(.light, .normal) != fill(.light, .high))
        #expect(try fill(.dark, .normal) != fill(.dark, .high))
        #expect(try fill(.light, .normal) != fill(.dark, .normal))
    }

    @Test func theFormulaGivesTheKnownRatios() {
        #expect(abs(Self.contrast(.white, .black) - 21) < 0.01)
        #expect(abs(Self.contrast(.white, .white) - 1) < 0.01)
    }

    // MARK: - WCAG 2 contrast

    static func components(_ color: UIColor) -> [CGFloat] {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return [red, green, blue, alpha]
    }

    static func luminance(_ color: UIColor) -> Double {
        let channels = components(color).prefix(3).map { value -> Double in
            let channel = min(max(Double(value), 0), 1)
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2]
    }

    static func contrast(_ first: UIColor, _ second: UIColor) -> Double {
        let (a, b) = (luminance(first), luminance(second))
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}
