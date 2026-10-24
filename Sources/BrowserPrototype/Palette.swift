import SwiftUI

// Default catalog variants serve light mode; explicit DarkAqua variants serve dark mode.
enum Palette {
    static func color(_ name: String, scheme: ColorScheme) -> Color {
        switch name {
        case "CommandBarTextPrimary":
            return scheme == .dark
                ? Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.800000011920929)
                : Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.800000011920929)
        case "CommandBarTextSecondary":
            return scheme == .dark
                ? Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.33000001311302185)
                : Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.33000001311302185)
        case "CommandBarRowHover":
            return scheme == .dark
                ? Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.05000000074505806)
                : Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.05000000074505806)
        case "SidebarItemBackground":
            return scheme == .dark
                ? Color(.displayP3, red: 0.9800000190734863, green: 0.984000027179718, blue: 1, opacity: 0.10000000149011612)
                : Color(.displayP3, red: 0.054999999701976776, green: 0.05900000035762787, blue: 0.06300000101327896, opacity: 0.05000000074505806)
        case "SidebarItemHovered":
            return scheme == .dark
                ? Color(.displayP3, red: 0.9800000190734863, green: 0.984000027179718, blue: 1, opacity: 0.15000000596046448)
                : Color(.displayP3, red: 0.054999999701976776, green: 0.05900000035762787, blue: 0.06300000101327896, opacity: 0.10000000149011612)
        case "TabCellBackgroundCurrent":
            return scheme == .dark
                ? Color(.displayP3, red: 0.9800000190734863, green: 0.984000027179718, blue: 1, opacity: 0.20000000298023224)
                : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.8500000238418579)
        case "TabCellBackgroundContentVisible":
            return scheme == .dark
                ? Color(.displayP3, red: 0.9800000190734863, green: 0.984000027179718, blue: 1, opacity: 0.15000000596046448)
                : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.699999988079071)
        case "TabCellBackgroundPressed":
            return scheme == .dark
                ? Color(.displayP3, red: 0.9800000190734863, green: 0.984000027179718, blue: 1, opacity: 0.06499999761581421)
                : Color(.displayP3, red: 0.054999999701976776, green: 0.05900000035762787, blue: 0.06300000101327896, opacity: 0.06499999761581421)
        case "TabCellShadowBackgroundSelected":
            return scheme == .dark
                ? Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0)
                : Color(.sRGB, red: 1, green: 1, blue: 1, opacity: 0.8999999761581421)
        case "TabCellShadowSelected":
            return scheme == .dark
                ? Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0)
                : Color(.sRGB, red: 0, green: 0, blue: 0, opacity: 0.20000000298023224)
        case "PrimaryButtonFace":
            return Color(.sRGB, red: 0.19215686274509805, green: 0.2235294117647059, blue: 0.984313725490196, opacity: 1)
        case "ArcMenuBackground":
            return scheme == .dark
                ? Color(.sRGB, red: 0.2235294117647059, green: 0.2196078431372549, blue: 0.2549019607843137, opacity: 1)
                : Color(.sRGB, red: 0.9803921568627451, green: 0.984313725490196, blue: 1, opacity: 1)
        default:
            assertionFailure("Unknown Palette token: \(name)")
            return .clear
        }
    }
}
