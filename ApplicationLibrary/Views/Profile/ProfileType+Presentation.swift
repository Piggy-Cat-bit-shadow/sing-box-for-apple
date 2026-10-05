import Library
import SwiftUI

extension ProfileType {
    /// UI presentation intentionally keeps iCloud distinct from Local/Remote export semantics.
    var presentationLabel: LocalizedStringKey {
        switch self {
        case .local:
            return "Local"
        case .icloud:
            return "iCloud"
        case .remote:
            return "Remote"
        }
    }

    /// The icon tile tint for this type.
    ///
    /// The roles come from the shared design system, so a profile row, a tool row and a
    /// settings row express "where does this live" with the same vocabulary rather than each
    /// picking a colour.
    var hakoAccent: HakoAccentRole {
        switch self {
        case .local:
            return .indigo
        case .icloud:
            return .cyan
        case .remote:
            return .teal
        }
    }

    var presentationSymbol: String {
        switch self {
        case .local:
            return "doc.fill"
        case .icloud:
            return "icloud.fill"
        case .remote:
            return "cloud.fill"
        }
    }
}
