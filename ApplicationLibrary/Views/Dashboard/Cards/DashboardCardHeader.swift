import SwiftUI

/// A card's heading: an icon and a caption, in the HAKO/Clash card language.
///
/// This used to be a bold `headline` with the icon in the primary colour. The
/// reference design reserves weight for the row titles and keeps card headings as
/// captions, so the cards read as containers rather than as competing headlines.
public struct DashboardCardHeader: View {
    private let icon: String
    private let title: LocalizedStringKey
    private let tint: Color?

    public init(icon: String, title: LocalizedStringKey, tint: Color? = nil) {
        self.icon = icon
        self.title = title
        self.tint = tint
    }

    public var body: some View {
        HakoCardTitle(title, systemImage: icon, tint: tint)
    }
}
