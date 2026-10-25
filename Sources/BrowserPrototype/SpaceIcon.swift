import BrowserCore
import SwiftUI

/// A Space's icon: an SF Symbol, or an emoji (Spaces imported from Arc carry emoji icons).
struct SpaceIcon: View {
    let icon: String

    var body: some View {
        if AppearancePreferences.isEmojiIcon(icon) { Text(icon) } else { Image(systemName: icon) }
    }
}

/// A Space's name with its icon, for menus, which only show image icons: emoji go in front of the name.
@ViewBuilder func spaceLabel(_ name: String, icon: String) -> some View {
    if AppearancePreferences.isEmojiIcon(icon) { Text("\(icon)  \(name)") } else { Label(name, systemImage: icon) }
}
