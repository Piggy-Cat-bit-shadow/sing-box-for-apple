import Foundation

/// A remote profile fetch: the body, plus the one response header this client cares about.
///
/// The body is what `HTTPClient.getString(...)` would have returned. `subscriptionUserInfo` is the
/// raw `subscription-userinfo` header of the **final** response, after any redirects, or `nil` when
/// the server did not send one. It is kept raw rather than parsed here: deciding what a malformed
/// or absent header means belongs to `SubscriptionInfo.parse(header:)` and the refresh policy, and
/// a fetch layer that silently turned "absent" into `nil` and "malformed" into `nil` would make
/// those two cases indistinguishable to the caller.
public struct RemoteProfileResponse: Equatable, Sendable {
    public let content: String
    public let subscriptionUserInfo: String?

    public init(content: String, subscriptionUserInfo: String?) {
        self.content = content
        self.subscriptionUserInfo = subscriptionUserInfo
    }

    /// The header name a subscription panel uses, case-insensitively as HTTP requires.
    public static let subscriptionUserInfoHeader = "subscription-userinfo"
}

/// Fetching a remote subscription configuration, with response metadata.
///
/// The body comes from `URLSession`, whose `HTTPURLResponse` can report the final response's
/// headers. The client's existing `HTTPClient.getString(...)` uses Libbox, whose
/// `LibboxHTTPResponse` protocol exposes only `getContent`, `writeTo` and `writeToWithProgress` -
/// there is no header accessor on either side of the Go binding - so it cannot serve this need
/// without extending the Go kernel's HTTP API and rebuilding the xcframework.
///
/// Only the remote-profile refresh uses this path. Every other caller of
/// `HTTPClient.getString(...)` keeps using Libbox exactly as before.
public enum RemoteProfileFetcher {
    /// The cache policy every subscription request uses.
    ///
    /// Exposed as a named constant rather than written inline at the two call sites for two
    /// reasons: the two requests must not drift apart, and the policy is something the tests
    /// assert directly instead of something a reader has to eyeball.
    ///
    /// `reloadIgnoringLocalCacheData` and not the default `.useProtocolCachePolicy`: a panel's
    /// usage counter moves on every request while its `Cache-Control` may invite reuse, so a
    /// cached response would hand back both the old body and the old `subscription-userinfo`. A
    /// quota read out of the HTTP cache is precisely the stale value this change exists to stop
    /// presenting as fresh.
    public static let cachePolicy: URLRequest.CachePolicy = .reloadIgnoringLocalCacheData

    /// Fetch a remote profile, following redirects and reporting the final response's
    /// `subscription-userinfo`.
    public static func fetch(_ url: String?) async throws -> RemoteProfileResponse {
        #if DEBUG
            precondition(!Thread.isMainThread, "RemoteProfileFetcher.fetch(...) must not be called on the main thread")
        #endif
        guard let url else {
            throw RemoteProfileFetchError.missingURL
        }
        guard let parsedURL = URL(string: url) else {
            throw RemoteProfileFetchError.missingURL
        }
        var request = URLRequest(url: parsedURL, cachePolicy: cachePolicy, timeoutInterval: 60)
        // The same User-Agent the Libbox client sends, so switching this fetch to URLSession does
        // not change what a panel sees. A panel that serves a different plan by User-Agent would
        // otherwise start answering this client differently.
        request.setValue(HTTPClient.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpMethod = "GET"

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProfileFetchError.notHTTP
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw RemoteProfileFetchError.badStatus(http.statusCode)
        }
        guard let content = String(data: data, encoding: .utf8) else {
            throw RemoteProfileFetchError.undecodableBody
        }
        // `HTTPURLResponse.value(forHTTPHeaderField:)` is case-insensitive and reports the final
        // response, so this is the last hop's header rather than a redirect's.
        let userInfo = http.value(forHTTPHeaderField: RemoteProfileResponse.subscriptionUserInfoHeader)
        return RemoteProfileResponse(content: content, subscriptionUserInfo: userInfo)
    }

    /// Fetch only the quota metadata, discarding the body.
    ///
    /// This is the second half of the transport fix. `fetch` above sees response headers, but a
    /// panel only *sends* `subscription-userinfo` to clients it recognises as Clash-family, and
    /// this client's own identity deliberately is not one. So when the primary response carries no
    /// quota, this makes one extra request under a Clash-compatible User-Agent purely to read the
    /// header.
    ///
    /// The body is discarded on purpose, and must never be treated as a configuration: it was
    /// fetched under a different identity and a panel may well have answered with a different
    /// *format* (Clash YAML where sing-box JSON is required). Only the header is used.
    ///
    /// The request is explicitly uncached - a quota read out of the HTTP cache is exactly the
    /// stale value this whole change exists to stop presenting as fresh - and carries a short
    /// timeout so a slow panel cannot hold up a refresh. It is only issued when the primary
    /// response captured nothing, so a panel that already sends the header costs no extra request.
    ///
    /// Throws on transport or status failure; the caller deliberately ignores that, because a
    /// quota is not worth failing a configuration refresh over.
    public static func captureMetadata(_ url: String) async throws -> SubscriptionInfoCapture {
        #if DEBUG
            precondition(!Thread.isMainThread, "RemoteProfileFetcher.captureMetadata(...) must not be called on the main thread")
        #endif
        guard let parsedURL = URL(string: url) else {
            throw RemoteProfileFetchError.missingURL
        }
        var request = URLRequest(url: parsedURL, cachePolicy: cachePolicy, timeoutInterval: 15)
        request.setValue(HTTPClient.subscriptionMetadataUserAgent, forHTTPHeaderField: "User-Agent")
        request.httpMethod = "GET"

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RemoteProfileFetchError.notHTTP
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw RemoteProfileFetchError.badStatus(http.statusCode)
        }
        return SubscriptionInfo.capture(
            header: http.value(forHTTPHeaderField: RemoteProfileResponse.subscriptionUserInfoHeader)
        )
    }
}

public enum RemoteProfileFetchError: LocalizedError {
    case missingURL
    case notHTTP
    case badStatus(Int)
    case undecodableBody

    public var errorDescription: String? {
        switch self {
        case .missingURL:
            return "The profile has no remote URL."
        case .notHTTP:
            return "The subscription did not answer with an HTTP response."
        case .badStatus(let status):
            return "HTTP \(status)"
        case .undecodableBody:
            return "The subscription is not UTF-8 text."
        }
    }
}
