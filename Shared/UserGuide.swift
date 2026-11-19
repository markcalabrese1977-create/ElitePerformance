import SwiftUI
import WebKit
import UIKit

/// The bundled user guide: `Guide.html` and the screenshots it references (`ElitePerformance/Resources/Guide/`).
///
/// The synchronized app group copies those files FLAT into the bundle root, so the page's relative `<img src="x.png">`
/// paths resolve beside it. Because the folder is the bundle root, read access is narrower than the folder: the only
/// page that may be shown is `Guide.html` itself (see `navigationDecision`).
enum UserGuide {

    static let fileName = "Guide"
    static let fileExtension = "html"

    /// Where support mail goes. A developer constant, not a user's data: the same address is printed in the guide.
    static let supportEmail = "eliteperformanceapp@gmail.com"

    /// The guide page inside `bundle`, or nil if it was not bundled.
    static func guideURL(in bundle: Bundle = .main) -> URL? {
        bundle.url(forResource: fileName, withExtension: fileExtension)
    }

    /// `mailto:` link for "Contact support", filled with the running build: subject "Elite Performance 1.2.2 (5)".
    static func supportMailURL(version: String, build: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = supportEmail
        components.percentEncodedQuery = "subject=" + "Elite Performance \(version) (\(build))"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+#")))!
        return components.url
    }

    static var supportMailURLForThisBuild: URL? { supportMailURL(version: BuildInfo.version, build: BuildInfo.build) }

    enum Decision: Equatable {
        case allow
        case openExternally
        case cancel
    }

    /// What the guide's web view does with a navigation to `url`. The page may navigate within itself (`#anchors`);
    /// `mailto:` goes to Mail; everything else, including any network URL, is cancelled.
    static func navigationDecision(for url: URL, guideURL: URL) -> Decision {
        if url.scheme?.lowercased() == "mailto" { return .openExternally }
        guard url.isFileURL else { return .cancel }
        return url.standardizedFileURL.path == guideURL.standardizedFileURL.path ? .allow : .cancel
    }
}

/// The in-app User Guide: a local `WKWebView`, no network.
struct UserGuideView: View {
    var body: some View {
        Group {
            if let url = UserGuide.guideURL() {
                GuideWebView(guideURL: url)
            } else {
                ContentUnavailableView("The guide could not be found.", systemImage: "book.closed")
            }
        }
        .navigationTitle("User Guide")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct GuideWebView: UIViewRepresentable {
    let guideURL: URL

    func makeCoordinator() -> Coordinator { Coordinator(guideURL: guideURL) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.navigationDelegate = context.coordinator
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        // Read access is the folder that holds the page (the bundle root, where the images sit beside it).
        web.loadFileURL(guideURL, allowingReadAccessTo: guideURL.deletingLastPathComponent())
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        let guideURL: URL
        init(guideURL: URL) { self.guideURL = guideURL }

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                     decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
            switch UserGuide.navigationDecision(for: url, guideURL: guideURL) {
            case .allow:
                decisionHandler(.allow)
            case .openExternally:
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            case .cancel:
                decisionHandler(.cancel)
            }
        }
    }
}
