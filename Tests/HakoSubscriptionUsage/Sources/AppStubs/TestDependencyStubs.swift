// The two symbols `Library/Network/RemoteProfileFetcher.swift` reaches outside the Foundation
// module, supplied so that file can be compiled and linked by the tests without the app target.
//
// The real `HTTPClient` lives in `Library/Network/HTTPClient.swift` and the real `Variant` in
// `Library/Shared/Variant.swift`; neither can be compiled here, because the former imports Libbox
// and the latter pulls in the app's build configuration. Only the User-Agent string matters to the
// fetch path, and the tests never perform a request, so these stay deliberately inert.

import Foundation

public enum HTTPClient {
    /// Matches the shape of the real value: application name, version, language.
    public static var userAgent: String {
        "HakoTest (sing-box stub; language en_US)"
    }
}

public enum Variant {
    public static let applicationName = "HakoTest"
}
