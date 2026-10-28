// The two symbols `Library/Network/RemoteProfileFetcher.swift` reaches outside the Foundation
// module, supplied so that file can be compiled and linked by the tests without the app target.
//
// The real `HTTPClient` lives in `Library/Network/HTTPClient.swift` and the real `Variant` in
// `Library/Shared/Variant.swift`; neither can be compiled here, because the former imports Libbox
// and the latter pulls in the app's build configuration. Only the User-Agent string matters to the
// fetch path, and the tests never perform a request, so these stay deliberately inert.

import Foundation

public enum HTTPClient {
    /// Mirrors the real marker in `Library/Network/HTTPClient.swift`. Duplicated because this stub
    /// stands in for the app symbol rather than sharing code with it; if the real value changes,
    /// this one has to change with it.
    public static let clashCompatibleMarker = "clash-verge/v2.5.0"

    /// Matches the shape of the real value: application name, version, language.
    public static var userAgent: String {
        "HakoTest (sing-box stub; language en_US)"
    }

    /// Mirrors the real fixed identity the subscription body request carries.
    public static let subscriptionUserAgent = "sing-box/1.15.0"

    /// Mirrors the real `subscriptionMetadataUserAgent`: the identity above plus the
    /// Clash-compatibility marker the metadata probe needs. The probe's request is asserted
    /// against this value, so the marker being present is testable here.
    public static var subscriptionMetadataUserAgent: String {
        userAgent + " " + clashCompatibleMarker
    }
}

public enum Variant {
    public static let applicationName = "HakoTest"
}
