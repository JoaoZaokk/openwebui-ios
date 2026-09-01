import SwiftUI
import WebKit
import OpenWebUIKit

/// The browser half of SSO (issue #13).
///
/// Open WebUI runs OAuth server-side: the app opens `/oauth/{provider}/login`,
/// the server redirects to the identity provider, the provider comes back to the
/// server's own callback, and the server exchanges the code, mints its JWT and
/// **puts it in a `token` cookie** before redirecting to `/auth`. The token never
/// appears in a URL.
///
/// That single fact rules out `ASWebAuthenticationSession`, which only hands back
/// a URL and only when it matches a scheme the app registered — neither of which
/// happens here. So the flow runs in a web view the app can read cookies from,
/// on an ephemeral data store. The cookie is deliberately not `HttpOnly` on the
/// server (`oauth.py:2172`, "Required for frontend access"), which is exactly why
/// this can work at all.
///
/// The store being ephemeral is not tidiness: with the shared one, the provider's
/// own session outlives a logout, and the next person to tap "sign in" on a
/// shared device is silently signed in as the previous one.
struct SSOWebLoginView: View {
    let provider: String
    let label: String
    let start: URL
    /// Called with the session token, or with a message when the flow failed.
    let finished: (Result<String, SSOError>) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            SSOWebView(start: start) { result in
                finished(result)
                dismiss()
            }
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(L("Entrar com %@", label))
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") { dismiss() }
                }
            }
        }
    }
}

enum SSOError: Error, LocalizedError {
    /// The server redirected to `/auth?error=…`.
    case server(String)
    /// The flow reached the end but no session cookie was there to read.
    case noToken

    var errorDescription: String? {
        switch self {
        case .server(let m): return m
        case .noToken:      return L("Não foi possível concluir o login.")
        }
    }
}

// MARK: - The web view

/// Watches for the one navigation that means the flow is over, then reads the
/// cookie the server just set.
private struct SSOWebView {
    let start: URL
    let done: (Result<String, SSOError>) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeWebView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: cfg)
        web.navigationDelegate = context.coordinator
        web.load(URLRequest(url: start))
        return web
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        private let done: (Result<String, SSOError>) -> Void
        /// The flow ends once. Without this, a redirect chain through `/auth` could
        /// report twice and dismiss a sheet that is already gone.
        private var settled = false

        init(done: @escaping (Result<String, SSOError>) -> Void) { self.done = done }

        func webView(_ webView: WKWebView,
                     decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard !settled, let url = navigationAction.request.url,
                  OpenWebUIClient.isOAuthCompletion(url) else {
                decisionHandler(.allow)
                return
            }
            settled = true
            decisionHandler(.cancel)   // no need to render the web app's own login page

            if let message = OpenWebUIClient.oauthError(in: url) {
                done(.failure(.server(message.removingPercentEncoding ?? message)))
                return
            }
            // The cookie belongs to whatever origin the server redirected to,
            // which is not necessarily the API's — an admin can set WEBUI_URL to
            // a different host. Take the token cookie wherever it landed.
            webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                let token = cookies.first { $0.name == "token" }?.value
                DispatchQueue.main.async {
                    if let token, !token.isEmpty { self.done(.success(token)) }
                    else { self.done(.failure(.noToken)) }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            report(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!,
                     withError error: Error) {
            report(error)
        }

        private func report(_ error: Error) {
            // A cancelled load is the one we asked for above, not a failure.
            guard !settled, (error as? URLError)?.code != .cancelled else { return }
            settled = true
            done(.failure(.server(error.localizedDescription)))
        }
    }
}

#if os(iOS)
extension SSOWebView: UIViewRepresentable {
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ web: WKWebView, context: Context) {}
}
#else
extension SSOWebView: NSViewRepresentable {
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ web: WKWebView, context: Context) {}
}
#endif

/// Clears everything the SSO web view left behind.
///
/// Signing out of Open WebUI does nothing to the identity provider's own cookies,
/// and those live in the web view, not in `URLSession`. Left alone, the next
/// "sign in with…" walks straight back into the same account without asking —
/// which on a shared device is someone else's.
enum SSOWebSession {
    static func clear() async {
        let store = WKWebsiteDataStore.nonPersistent()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        await store.removeData(ofTypes: types, modifiedSince: .distantPast)
        await WKWebsiteDataStore.default().removeData(ofTypes: types, modifiedSince: .distantPast)
    }
}
