import SwiftUI
import WebKit

struct WebArticleView: View {
    let url: URL
    @State private var progress: Double = 0
    @State private var title: String = ""

    var body: some View {
        ZStack(alignment: .top) {
            WebViewRepresentable(url: url, progress: $progress, title: $title)
                .ignoresSafeArea(edges: .bottom)
            if progress < 1 {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
            }
        }
    }
}

private struct WebViewRepresentable: UIViewRepresentable {
    let url: URL
    @Binding var progress: Double
    @Binding var title: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: cfg)
        view.navigationDelegate = context.coordinator
        view.allowsBackForwardNavigationGestures = true
        view.addObserver(context.coordinator, forKeyPath: "estimatedProgress", options: .new, context: nil)
        view.addObserver(context.coordinator, forKeyPath: "title", options: .new, context: nil)
        view.load(URLRequest(url: url))
        context.coordinator.observed = view
        return view
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ view: WKWebView, coordinator: Coordinator) {
        view.removeObserver(coordinator, forKeyPath: "estimatedProgress")
        view.removeObserver(coordinator, forKeyPath: "title")
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        let parent: WebViewRepresentable
        weak var observed: WKWebView?
        init(_ parent: WebViewRepresentable) { self.parent = parent }

        override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                                   change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
            guard let webView = observed else { return }
            DispatchQueue.main.async {
                if keyPath == "estimatedProgress" {
                    self.parent.progress = webView.estimatedProgress
                } else if keyPath == "title" {
                    self.parent.title = webView.title ?? ""
                }
            }
        }
    }
}
