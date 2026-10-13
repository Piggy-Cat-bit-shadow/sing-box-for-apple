import Foundation
import Libbox

public class HTTPClient {
    /// The User-Agent every outgoing request carries, including the `URLSession`-based
    /// `RemoteProfileFetcher`. Public so that moving a request between the two transports cannot
    /// change what a server sees.
    ///
    /// It is built from `Variant.applicationName`, which is the target's identity ("SFI"/"SFM") and
    /// deliberately not the user-visible product name: a panel that answers a different plan by
    /// User-Agent must keep seeing the same string it saw before the rename.
    public static var userAgent: String {
        var userAgent = Variant.applicationName
        userAgent += " (sing-box "
        userAgent += LibboxVersion()
        userAgent += "; language "
        userAgent += Locale.current.identifier
        userAgent += ")"
        return userAgent
    }

    /// The marker a panel looks for when deciding whether to send `subscription-userinfo`.
    ///
    /// Panels commonly withhold that header from clients they do not recognise as Clash-family,
    /// and the app's own identity above carries no such marker - the header is then never sent and
    /// no quota is ever captured, which is why the quota can appear frozen at whatever value was
    /// last obtained by some other client.
    ///
    /// The marker is a separate value rather than a change to `Variant.applicationName`, which
    /// this repository's `branding` and `subscription-feature` audits assert must stay `SFI`/
    /// `SFM`/`SFT`: that name is a release contract (bundle identity, VPN profile description,
    /// Siri phrases), not display copy.
    public static let clashCompatibleMarker = "clash-verge/v2.5.0"

    /// The User-Agent used **only** by the secondary metadata probe.
    ///
    /// Deliberately not used for the request that fetches the configuration body. A panel is
    /// entitled to choose the subscription *format* by User-Agent, so asking for the body as a
    /// Clash client risks receiving Clash YAML where sing-box JSON is required - a far worse
    /// failure than a stale quota. The probe discards the body and keeps only the header, which
    /// lets the body-producing request keep the identity that keeps the format correct.
    public static var subscriptionMetadataUserAgent: String {
        userAgent + " " + clashCompatibleMarker
    }

    private let client: any LibboxHTTPClientProtocol

    public init() {
        client = LibboxNewHTTPClient()!
        client.modernTLS()
    }

    public func getString(_ url: String?, headers: [String: String] = [:]) throws -> String {
        #if DEBUG
            precondition(!Thread.isMainThread, "HTTPClient.getString(...) must not be called on the main thread")
        #endif
        let request = client.newRequest()!
        request.setUserAgent(HTTPClient.userAgent)
        for (key, value) in headers {
            request.setHeader(key, value: value)
        }
        try request.setURL(url)
        let response = try request.execute()
        let content = try response.getContent()
        return content.value
    }

    public func getStringAsync(_ url: String?) async throws -> String {
        try await Self.getStringAsync(url)
    }

    public static func getStringAsync(_ url: String?) async throws -> String {
        try await BlockingIO.run {
            try HTTPClient().getString(url)
        }
    }

    public func writeTo(_ url: String?, path: String, progress: ((Int64, Int64) -> Void)? = nil) throws {
        #if DEBUG
            precondition(!Thread.isMainThread, "HTTPClient.writeTo(...) must not be called on the main thread")
        #endif
        let request = client.newRequest()!
        request.setUserAgent(HTTPClient.userAgent)
        try request.setURL(url)
        let response = try request.execute()
        if let progress {
            let handler = WriteToProgressHandler(progress)
            try response.writeTo(withProgress: path, handler: handler)
        } else {
            try response.write(to: path)
        }
    }

    public static func writeToAsync(_ url: String?, path: String, progress: ((Int64, Int64) -> Void)? = nil) async throws {
        try await BlockingIO.run {
            try HTTPClient().writeTo(url, path: path, progress: progress)
        }
    }

    deinit {
        client.close()
    }
}

private class WriteToProgressHandler: NSObject, LibboxHTTPResponseWriteToProgressHandlerProtocol {
    private let handler: (Int64, Int64) -> Void

    init(_ handler: @escaping (Int64, Int64) -> Void) {
        self.handler = handler
    }

    func update(_ progress: Int64, total: Int64) {
        handler(progress, total)
    }
}
