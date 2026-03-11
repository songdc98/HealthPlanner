import SwiftUI

enum AppTheme {
    static let backgroundTop = Color(red: 0.06, green: 0.06, blue: 0.07)
    static let backgroundBottom = Color(red: 0.03, green: 0.03, blue: 0.04)
    static let panelBackground = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let panelStroke = Color.white.opacity(0.10)

    static let accentPrimary = Color(red: 0.36, green: 0.78, blue: 0.62)
    static let accentSecondary = Color(red: 0.78, green: 0.80, blue: 0.86)
    static let accentWarm = Color(red: 0.93, green: 0.70, blue: 0.37)

    static let title = Font.system(size: 30, weight: .bold, design: .rounded)
    static let cardTitle = Font.system(size: 21, weight: .semibold, design: .rounded)
    static let body = Font.system(size: 18, weight: .regular)
    static let bodyStrong = Font.system(size: 19, weight: .semibold)
    static let caption = Font.system(size: 15, weight: .regular)

    static let cornerRadius: CGFloat = 18
}
