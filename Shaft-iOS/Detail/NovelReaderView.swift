import SwiftUI

@MainActor
@Observable
final class NovelReaderViewModel {
    let novelId: Int64
    var title: String = ""
    var author: String = ""
    var rawText: String = ""
    var pages: [String] = []
    var isLoading = false
    var errorMessage: String?

    @ObservationIgnored private let api: PixivAPI

    init(novelId: Int64) {
        self.novelId = novelId
        self.api = PixivAPI.make(tokenProvider: AuthTokenProvider.shared)
    }

    func loadIfNeeded() async {
        if rawText.isEmpty { await load() }
    }

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            // Pixiv `/webview/v2/novel?id=` returns an HTML page that embeds
            // the novel in a JSON blob. Shaft's `WebNovelParser` extracts the
            // `text` field from `pixiv.context = { … }`. We replicate the
            // extraction here.
            let data = try await api.novelText(novelId)
            guard let html = String(data: data, encoding: .utf8) else {
                errorMessage = "Decoding failed"
                return
            }
            let extracted = NovelHTMLExtractor.extract(from: html)
            title = extracted.title
            author = extracted.author
            rawText = extracted.text
            pages = paginate(extracted.text)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Greedy by-character paginator. Pixiv novels use `\n\n` for paragraph
    /// breaks; we stop at the last paragraph that fits the page budget.
    private func paginate(_ text: String, charsPerPage: Int = 1100) -> [String] {
        guard !text.isEmpty else { return [] }
        var pages: [String] = []
        var current = ""
        for paragraph in text.components(separatedBy: "\n\n") {
            if current.count + paragraph.count + 2 > charsPerPage, !current.isEmpty {
                pages.append(current)
                current = ""
            }
            if !current.isEmpty { current += "\n\n" }
            current += paragraph
        }
        if !current.isEmpty { pages.append(current) }
        return pages
    }
}

enum NovelHTMLExtractor {
    struct Extracted { let title: String; let author: String; let text: String }

    static func extract(from html: String) -> Extracted {
        // pixiv.context = {…};   — single-line JSON-ish blob.
        let pattern = #"pixiv\.context\s*=\s*(\{.*?\});"#
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let match = regex.firstMatch(in: html, range: range),
              let blobRange = Range(match.range(at: 1), in: html) else {
            return Extracted(title: "", author: "", text: stripHTML(html))
        }
        let blob = String(html[blobRange])

        let title = stringField("title", in: blob) ?? ""
        let author = stringField("authorDetails.userName", in: blob)
            ?? stringField("authorName", in: blob) ?? ""
        let text = stringField("text", in: blob)
            .map(unescapeJSON)
            ?? stripHTML(html)

        return Extracted(title: title, author: author, text: text)
    }

    private static func stringField(_ name: String, in blob: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let pattern = "\"\(escaped)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: blob, range: NSRange(blob.startIndex..<blob.endIndex, in: blob)),
              let r = Range(match.range(at: 1), in: blob) else { return nil }
        return String(blob[r])
    }

    private static func unescapeJSON(_ s: String) -> String {
        s.replacingOccurrences(of: "\\n", with: "\n")
         .replacingOccurrences(of: "\\r", with: "")
         .replacingOccurrences(of: "\\\"", with: "\"")
         .replacingOccurrences(of: "\\/", with: "/")
         .replacingOccurrences(of: "\\\\", with: "\\")
    }

    private static func stripHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "<.+?>", with: "", options: .regularExpression)
         .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}

/// V3-style novel reader: paged horizontal swipe, dimmable background, top bar
/// with title, bottom bar with progress.
struct NovelReaderView: View {
    let novelId: Int64
    @State private var vm: NovelReaderViewModel
    @State private var page: Int = 0
    @Environment(\.dismiss) private var dismiss

    init(novelId: Int64) {
        self.novelId = novelId
        _vm = State(wrappedValue: NovelReaderViewModel(novelId: novelId))
    }

    var body: some View {
        ZStack {
            Color(red: 0.99, green: 0.97, blue: 0.93).ignoresSafeArea()

            if vm.pages.isEmpty {
                if vm.isLoading {
                    ProgressView()
                } else if let err = vm.errorMessage {
                    InlineError(message: err) { Task { await vm.load() } }.padding()
                }
            } else {
                TabView(selection: $page) {
                    ForEach(Array(vm.pages.enumerated()), id: \.offset) { i, content in
                        ScrollView {
                            Text(content)
                                .font(.system(size: 18, weight: .regular, design: .serif))
                                .lineSpacing(8)
                                .padding(.horizontal, 24)
                                .padding(.vertical, 60)
                        }
                        .tag(i)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }

            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.thinMaterial, in: .circle)
                    }
                    Spacer()
                    if !vm.title.isEmpty {
                        Text(vm.title).font(.footnote.bold()).lineLimit(1)
                    }
                    Spacer()
                    Color.clear.frame(width: 36, height: 36)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                Spacer()
                if !vm.pages.isEmpty {
                    HStack {
                        Text("\(page + 1) / \(vm.pages.count)")
                            .font(.caption.bold())
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .background(.thinMaterial, in: .capsule)
                    }
                    .padding(.bottom, 16)
                }
            }
        }
        .task { await vm.loadIfNeeded() }
    }
}
