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
        // The subscription body uses the stable sing-box identity on both transports, so a panel
        // sees the same string from the first import and every refresh. `HTTPClient.userAgent`
        // stays the app's own identity for GitHub updates, rule-set downloads and other requests.
        request.setValue(HTTPClient.subscriptionUserAgent, forHTTPHeaderField: "User-Agent")
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

    /// Fetch only the quota metadata, stopping the body as soon as the headers arrive.
    ///
    /// This is the second half of the transport fix. `fetch` above sees response headers, but a
    /// panel only *sends* `subscription-userinfo` to clients it recognises as Clash-family, and
    /// this client's own identity deliberately is not one. So when the primary response carries no
    /// quota, this makes one extra request under a Clash-compatible User-Agent purely to read the
    /// header.
    ///
    /// # Why this is not `URLSession.data(for:)`
    ///
    /// `data(for:)` resolves only once the whole body has been transferred, so it downloads the
    /// entire subscription a second time and then throws the bytes away. For a large subscription
    /// that is real traffic, latency, memory and server bandwidth spent on one response header. The
    /// probe therefore streams: it reads the header in
    /// `urlSession(_:dataTask:didReceive:completionHandler:)` and answers `.cancel`, which stops the
    /// transfer before the body is read.
    ///
    /// # The body is never used
    ///
    /// It must not be treated as a configuration: it was fetched under a different identity, and a
    /// panel may well have answered with a different *format* (Clash YAML where sing-box JSON is
    /// required). Only the header is read, and the body is never buffered at all.
    ///
    /// # Freshness
    ///
    /// The request bypasses the local URL loading cache and asks intermediaries to revalidate: a
    /// quota served from a shared cache is exactly the stale value this whole change exists to stop
    /// presenting as fresh.
    ///
    /// Throws on transport or status failure; the caller deliberately ignores that, because a quota
    /// is not worth failing a configuration refresh over.
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
        // `cachePolicy` governs this client's own URL loading cache. This header is what asks a
        // shared intermediary to revalidate, and it is a standard request header rather than a
        // cache-busting query parameter - the subscription URL may carry an authentication
        // signature, and rewriting it would break the request.
        request.setValue(cacheRevalidationDirective, forHTTPHeaderField: "Cache-Control")

        return try await SubscriptionMetadataProbe().run(request)
    }

    /// What the metadata probe asks intermediaries to do with their copy.
    ///
    /// `no-cache` rather than `no-store`: the response may still be stored, it just may not be
    /// reused without revalidation. Uncovered by tests as a literal - the request-shape test
    /// asserts the header the probe actually sends.
    public static let cacheRevalidationDirective = "no-cache"
}

/// Reads one response's headers and stops the body.
///
/// Private and single-use on purpose: one probe owns one short-lived session, and the session is
/// invalidated as soon as the answer is known, so the delegate is released and nothing is left
/// behind. `URLSession` keeps its delegate alive until invalidation, which is what keeps this object
/// alive for the duration of the request.
private final class SubscriptionMetadataProbe: NSObject, URLSessionDataDelegate {
    private var continuation: CheckedContinuation<SubscriptionInfoCapture, Error>?
    private var session: URLSession?

    func run(_ request: URLRequest) async throws -> SubscriptionInfoCapture {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // Ephemeral: no persistent cache or cookie store to leave behind for a request whose
            // whole answer is one header.
            let session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
        }
    }

    func urlSession(
        _: URLSession,
        dataTask _: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(RemoteProfileFetchError.notHTTP))
            return
        }

        // A redirect's own response is delivered here first. It is not the answer - the quota has to
        // come from the last hop, and `fetch` reads it the same way - so allow the redirect and wait
        // for the response that replaces it.
        if (300 ..< 400).contains(http.statusCode) {
            completionHandler(.allow)
            return
        }

        // The headers are all this request came for. Stopping here is what keeps the body off the
        // wire; it is expected control flow, not a failure, and it must not overwrite the answer
        // below - which is why the result is finished before the cancel is reported back.
        completionHandler(.cancel)

        guard (200 ..< 300).contains(http.statusCode) else {
            finish(.failure(RemoteProfileFetchError.badStatus(http.statusCode)))
            return
        }
        finish(.success(SubscriptionInfo.capture(
            header: http.value(forHTTPHeaderField: RemoteProfileResponse.subscriptionUserInfoHeader)
        )))
    }

    /// Reached for the cancellation this object asked for, for a transport failure, and for a
    /// redirect that was never followed. `finish` is once-only, so the cancellation that follows a
    /// captured header cannot replace it.
    func urlSession(_: URLSession, task _: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            finish(.failure(error))
        } else {
            finish(.failure(RemoteProfileFetchError.notHTTP))
        }
    }

    private func finish(_ result: Result<SubscriptionInfoCapture, Error>) {
        guard let continuation else {
            return
        }
        self.continuation = nil
        // Cancels the transfer if it is still running, and releases the delegate this session is
        // holding. Without it the probe - and the continuation it owns - would outlive the request.
        session?.invalidateAndCancel()
        session = nil
        continuation.resume(with: result)
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
