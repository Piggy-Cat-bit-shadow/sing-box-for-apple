import Foundation
import SwiftUI

public struct SponsorsView: View {
    @Environment(\.openURL) private var openURL

    public init() {}
    public var body: some View {
        HakoSettingsScaffold(title: String(localized: "Sponsors")) {
            HakoFootnote("**If I've defended your modern life, please consider sponsoring me.**")

            HakoSettingsSection {
                Button {
                    openURL(URL(string: "https://github.com/sponsors/nekohasekai")!)
                } label: {
                    HakoNavigationRow(
                        title: String(localized: "GitHub Sponsors (recommended)"),
                        subtitle: String(localized: "Recurring support through GitHub"),
                        systemImage: "heart.fill",
                        tint: HakoAccentRole.neutral.color,
                        linksOut: true
                    )
                }
                .buttonStyle(HakoPushRowButtonStyle())


                Button {
                    openURL(URL(string: "https://sekai.icu/sponsors/")!)
                } label: {
                    HakoNavigationRow(
                        title: String(localized: "Other methods"),
                        subtitle: String(localized: "Other ways to contribute"),
                        systemImage: "creditcard.fill",
                        tint: HakoAccentRole.neutral.color,
                        linksOut: true
                    )
                }
                .buttonStyle(HakoPushRowButtonStyle())
            }
        }
    }
}
