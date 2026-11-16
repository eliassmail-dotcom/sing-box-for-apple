#if os(iOS)
import Foundation
import WebKit

/// Executes the user-supplied Yandex v1.4.48r2 generator byte-for-byte in
/// a network-disabled ephemeral WebKit context. Only native URLSession fetches
/// the source subscription. No token, subscription or generated JSON is logged.
@MainActor
public final class LocalGeneratorEngine: NSObject, WKNavigationDelegate {
    public struct Result: Decodable {
        public let ok: Bool
        public let json: String?
        public let nodeCount: Int?
        public let sourceNodeCount: Int?
        public let error: String?
    }

    public enum GeneratorError: LocalizedError {
        case invalidInput(String)
        case javascriptUnavailable
        case generation(String)
        case httpUnavailable

        public var errorDescription: String? {
            switch self {
            case let .invalidInput(message): message
            case .javascriptUnavailable: "Изолированный JS-движок не смог обработать генератор."
            case let .generation(code): "Генератор отклонил настройки или подписку: \(code)"
            case .httpUnavailable: "Источник подписки временно недоступен"
            }
        }
    }

    private var webView: WKWebView?
    private var pageContinuation: CheckedContinuation<Void, Error>?
    private var pageTimeoutTask: Task<Void, Never>?
    private var generationInProgress = false

    // Constrain the response *during* streaming, not only after URLSession
    // has already allocated the entire HTTP body.
    static func appendLimitedSubscriptionByte(
        _ byte: UInt8, to data: inout Data, limit: Int = 2_000_000
    ) throws {
        guard data.count < limit else {
            throw GeneratorError.invalidInput("Подписка превышает лимит 2 МБ")
        }
        data.append(byte)
    }

    public static func parseVariables(_ input: String) throws -> [String: String] {
        guard input.utf8.count <= 120_000 else {
            throw GeneratorError.invalidInput("Переменные окружения слишком длинные")
        }
        var result: [String: String] = [:]
        for (index, line) in input.components(separatedBy: .newlines).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.hasPrefix("#") { continue }
            guard let equals = trimmed.firstIndex(of: "=") else {
                throw GeneratorError.invalidInput("Строка \(index + 1): ожидается KEY=VALUE")
            }
            let key = String(trimmed[..<equals]).trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[trimmed.index(after: equals)...])
            guard !key.isEmpty,
                  key.first?.isLetter == true || key.first == "_",
                  key.utf8.allSatisfy({ c in
                      (c >= 65 && c <= 90) || (c >= 48 && c <= 57) || c == 95
                  }) else {
                throw GeneratorError.invalidInput("Строка \(index + 1): неверное имя переменной")
            }
            guard result[key] == nil else {
                throw GeneratorError.invalidInput("Повторяется переменная \(key)")
            }
            result[key] = value
        }
        return result
    }

    /// The body is already fetched by URLSession, or pasted by the user.
    public func generate(
        variables: [String: String], subscription: String,
        variant: String, core: String, platform: String, log: String
    ) async throws -> Result {
        let body = subscription.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty && body.utf8.count <= 2_000_000 else {
            throw GeneratorError.invalidInput("Пустая подписка или превышен лимит 2 МБ")
        }
        guard !generationInProgress else {
            throw GeneratorError.generation("GENERATOR_BUSY")
        }
        generationInProgress = true
        // Decode and verify the bundled script BEFORE starting WebKit.
        // A corrupted bundle must not create an orphaned WebContent process.
        defer {
            generationInProgress = false
            pageTimeoutTask?.cancel()
            pageTimeoutTask = nil
            webView?.stopLoading()
            webView?.navigationDelegate = nil
            webView = nil
        }
        let script = try LocalGeneratorBundle.javascript()
        try await preparePage()
        guard let webView else { throw GeneratorError.javascriptUnavailable }
        // Never embed untrusted input into executable JavaScript source.
        // The payload is UTF-8 JSON, then Base64-encoded and decoded in WebKit.
        let input: [String: Any] = [
            "env": variables, "raw": subscription, "variant": variant,
            "core": core, "platform": platform, "log": log,
        ]
        let inputData = try JSONSerialization.data(withJSONObject: input, options: [.sortedKeys])
        let encoded = inputData.base64EncodedString()
        do {
            _ = try await webView.evaluateJavaScript(script)
            let execute = "globalThis.__localYcGenerator(new TextDecoder().decode(Uint8Array.from(atob('" + encoded + "'), c => c.charCodeAt(0))))"
            guard let rawResult = try await webView.evaluateJavaScript(execute) as? String,
                  let response = rawResult.data(using: .utf8) else {
                throw GeneratorError.javascriptUnavailable
            }
            let result = try JSONDecoder().decode(Result.self, from: response)
            guard result.ok, let json = result.json, !json.isEmpty else {
                throw GeneratorError.generation(result.error ?? "UNCLASSIFIED_FAILURE")
            }
            return result
        } catch let error as GeneratorError {
            throw error
        } catch {
            // Raw WKJavaScriptExceptionMessage may contain parts of the script or
            // user data. Never send it to UI logs, crash reporters, or alerts.
            throw GeneratorError.javascriptUnavailable
        }
    }

    private func preparePage() async throws {
        let settings = WKWebViewConfiguration()
        settings.websiteDataStore = .nonPersistent()
        settings.defaultWebpagePreferences.allowsContentJavaScript = true
        let webView = WKWebView(frame: .zero, configuration: settings)
        self.webView = webView
        webView.navigationDelegate = self
        // Script runs via the native evaluateJavaScript bridge. The WebView
        // itself cannot access network, disk, forms, images, or any endpoint.
        let html = """
        <!doctype html><html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy"
              content="default-src 'none'; connect-src 'none'; img-src 'none'; frame-src 'none'; form-action 'none'; script-src 'unsafe-eval' 'unsafe-inline'">
        </head><body></body></html>
        """
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                pageContinuation = continuation
                pageTimeoutTask?.cancel()
                pageTimeoutTask = Task { @MainActor [weak self] in
                    do {
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    } catch {
                        return
                    }
                    self?.finishPage(error: GeneratorError.javascriptUnavailable)
                }
                webView.loadHTMLString(html, baseURL: nil)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finishPage(error: CancellationError())
            }
        }
    }

    /// Resume a checked continuation at most once, regardless of which
    /// navigation callback, cancellation or timeout wins the race.
    private func finishPage(error: Error? = nil) {
        let pending = pageContinuation
        pageContinuation = nil
        pageTimeoutTask?.cancel()
        pageTimeoutTask = nil
        guard let pending else { return }
        if let error {
            pending.resume(throwing: error)
        } else {
            pending.resume()
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === self.webView else { return }
        finishPage()
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        finishPage(error: GeneratorError.javascriptUnavailable)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        guard webView === self.webView else { return }
        finishPage(error: GeneratorError.javascriptUnavailable)
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === self.webView else { return }
        finishPage(error: GeneratorError.javascriptUnavailable)
    }

    public struct SubscriptionPayload {
        public enum Origin: String { case direct, yandexProxy }
        public let text: String
        public let origin: Origin
    }

    /// Direct first. Only connectivity failures or explicit access-blocking
    /// HTTP statuses may trigger the optional Yandex proxy. A malformed or
    /// unauthorized subscription must never silently become another profile.
    public static func loadSubscription(
        from rawURL: String, userAgent: String,
        proxyURL: String? = nil, proxyToken: String? = nil
    ) async throws -> SubscriptionPayload {
        do {
            let text = try await fetchSubscription(from: rawURL, userAgent: userAgent,
                                                    proxyKey: nil)
            return SubscriptionPayload(text: text, origin: .direct)
        } catch {
            let eligible: Bool
            if error is URLError {
                eligible = true
            } else if let failure = error as? GeneratorError, case .httpUnavailable = failure {
                eligible = true
            } else {
                eligible = false
            }
            guard eligible,
                  let proxyURL, !proxyURL.isEmpty,
                  let proxyToken, proxyToken.utf8.count >= 32 else { throw error }
            // The fixed source URL is configured on the Yandex server. Never
            // forward the original subscription URL or its query token.
            guard var components = URLComponents(string: proxyURL),
                  components.scheme?.lowercased() == "https",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else {
                throw GeneratorError.invalidInput("Адрес резервной Яндекс-функции должен быть HTTPS")
            }
            if components.queryItems?.contains(where: { $0.name.lowercased() == "source" }) == true {
                throw GeneratorError.invalidInput("Параметр source добавляется автоматически")
            }
            components.queryItems = (components.queryItems ?? []) +
                [URLQueryItem(name: "source", value: "subscription")]
            guard let url = components.url else {
                throw GeneratorError.invalidInput("Некорректный адрес резервной Яндекс-функции")
            }
            let text = try await fetchSubscription(from: url.absoluteString,
                                                   userAgent: userAgent, proxyKey: proxyToken)
            return SubscriptionPayload(text: text, origin: .yandexProxy)
        }
    }

    /// This intentionally does not expose the URL or any response body to
    /// analytics, crash reports, console messages, or UIAlert errors.
    private static func fetchSubscription(
        from rawURL: String, userAgent: String, proxyKey: String?
    ) async throws -> String {
        guard let url = URL(string: rawURL),
              url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else {
            throw GeneratorError.invalidInput("Адрес подписки должен быть корректным HTTPS URL")
        }
        guard !userAgent.contains("\n") && !userAgent.contains("\r") else {
            throw GeneratorError.invalidInput("USER_AGENT содержит недопустимые символы")
        }
        let redirects = HTTPSOnlyRedirectDelegate(allowRedirects: proxyKey == nil)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8.5
        config.timeoutIntervalForResource = 12
        config.httpCookieAcceptPolicy = .never
        config.httpShouldSetCookies = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: redirects, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                                 timeoutInterval: 8.5)
        request.setValue(userAgent.isEmpty ? "sing-box" : userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        if let proxyKey {
            // Custom header instead of ?key= in the URL, preventing token
            // exposure in browser history, CDN URL logs, and referrers.
            request.setValue(proxyKey, forHTTPHeaderField: "X-Subscription-Proxy-Key")
        }
        // AsyncBytes exposes the response headers before the body is collected
        // and cancels immediately once our strict limit is exceeded.
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeneratorError.invalidInput("Источник подписки вернул некорректный ответ")
        }
        guard (200...299).contains(http.statusCode) else {
            if proxyKey == nil && [403, 408, 429, 451, 500, 502, 503, 504].contains(http.statusCode) {
                throw GeneratorError.httpUnavailable
            }
            throw GeneratorError.invalidInput("Ошибка HTTP при загрузке подписки: \(http.statusCode)")
        }
        let maxBytes = 2_000_000
        guard http.expectedContentLength <= Int64(maxBytes) else {
            throw GeneratorError.invalidInput("Подписка превышает лимит 2 МБ")
        }
        var data = Data()
        if http.expectedContentLength > 0 {
            data.reserveCapacity(Int(min(http.expectedContentLength, Int64(maxBytes))))
        }
        for try await byte in bytes {
            try appendLimitedSubscriptionByte(byte, to: &data, limit: maxBytes)
        }
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            throw GeneratorError.invalidInput("Подписка пуста или не является UTF-8 текстом")
        }
        return text
    }

}

/// Limits redirects to 3 HTTPS destinations and rejects HTTP downgrades.
private final class HTTPSOnlyRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let allowRedirects: Bool

    init(allowRedirects: Bool) { self.allowRedirects = allowRedirects }

    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        lock.lock()
        count += 1
        let withinLimit = count <= 3
        lock.unlock()
        guard allowRedirects, withinLimit, request.url?.scheme?.lowercased() == "https",
              request.url?.host != nil, request.url?.user == nil, request.url?.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}
#endif