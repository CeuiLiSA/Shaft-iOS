import UIKit
import CoreText

// Novel export — port of upstream `reader/export/`: TXT (header + 【章节】 +
// page-break rules), Markdown (front-matter + ## chapters + linked images),
// PDF (A4 595×842 @ 48pt margins, cover page, chapters on fresh pages, 12pt
// serif body at 1.55 line height, [图片] placeholders) and EPUB 2.0 (hand-
// rolled stored ZIP: mimetype + container.xml + OPF + NCX + single XHTML +
// embedded JPEG-85 images, network failures degrade to text placeholders).
// Files are written to tmp and handed to the share sheet (iOS's Downloads/).

enum ReaderExportFormat: CaseIterable {
    case txt, markdown, epub, pdf

    var emoji: String {
        switch self {
        case .txt: return "📝"
        case .markdown: return "🆃"
        case .epub: return "📖"
        case .pdf: return "📄"
        }
    }

    var titleKey: LocalizedKey {
        switch self {
        case .txt: return .nrFormatTxt
        case .markdown: return .nrFormatMarkdown
        case .epub: return .nrFormatEpub
        case .pdf: return .nrFormatPdf
        }
    }

    var descKey: LocalizedKey {
        switch self {
        case .txt: return .nrExportTxtDesc
        case .markdown: return .nrExportMdDesc
        case .epub: return .nrExportEpubDesc
        case .pdf: return .nrExportPdfDesc
        }
    }

    var fileExtension: String {
        switch self {
        case .txt: return "txt"
        case .markdown: return "md"
        case .epub: return "epub"
        case .pdf: return "pdf"
        }
    }
}

struct ReaderExportInput {
    let novelId: Int64
    let title: String
    let author: String
    let caption: String
    let tags: [String]
    let tokens: [ContentToken]
    let webNovel: WebNovel?

    var sourceURL: String { "https://www.pixiv.net/novel/show.php?id=\(novelId)" }
}

enum ReaderExporter {
    static func export(_ input: ReaderExportInput, format: ReaderExportFormat) async throws -> URL {
        let safeTitle = sanitizeFileName(input.title.isEmpty ? "\(input.novelId)" : input.title)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeTitle)_\(input.novelId).\(format.fileExtension)")
        let data: Data
        switch format {
        case .txt: data = Data(buildTxt(input).utf8)
        case .markdown: data = Data(buildMarkdown(input).utf8)
        case .pdf: data = buildPdf(input)
        case .epub: data = try await buildEpub(input)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func sanitizeFileName(_ s: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return String(s.unicodeScalars.map { invalid.contains($0) ? "_" : Character($0) }.prefix(40))
    }

    // MARK: TXT

    private static func buildTxt(_ input: ReaderExportInput) -> String {
        var out = "\(input.title)\n\(input.author)\n\(input.sourceURL)\n\n"
        for token in input.tokens {
            switch token {
            case .chapter(_, _, let title):
                out += "\n【\(title)】\n\n"
            case .paragraph(_, _, let text, _, _):
                out += text + "\n"
            case .blankLine:
                out += "\n"
            case .pageBreak:
                out += "\n- - - - - - - - - -\n\n"
            case .pixivImage(_, _, let id, let page):
                out += page > 0 ? "[图片: pixiv \(id)-\(page)]\n" : "[图片: pixiv \(id)]\n"
            case .uploadedImage(_, _, let id):
                out += "[图片: \(id)]\n"
            case .jump(_, _, let target):
                out += "[跳转→第 \(target) 段]\n"
            }
        }
        return out
    }

    // MARK: Markdown

    private static func escapeMd(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
    }

    private static func buildMarkdown(_ input: ReaderExportInput) -> String {
        var out = "# \(escapeMd(input.title))\n\n"
        if !input.author.isEmpty { out += "**作者**：\(escapeMd(input.author))\n\n" }
        out += "**链接**：\(input.sourceURL)\n\n"
        if !input.tags.isEmpty { out += "**标签**：\(input.tags.map(escapeMd).joined(separator: " / "))\n\n" }
        if !input.caption.isEmpty {
            let quoted = input.caption.split(separator: "\n").map { "> \($0)" }.joined(separator: "\n")
            out += quoted + "\n\n"
        }
        out += "---\n\n"
        for token in input.tokens {
            switch token {
            case .chapter(_, _, let title):
                out += "\n## \(escapeMd(title))\n\n"
            case .paragraph(_, _, let text, _, _):
                out += escapeMd(text) + "\n\n"
            case .blankLine:
                out += "\n"
            case .pageBreak:
                out += "\n---\n\n"
            case .pixivImage, .uploadedImage:
                if let webNovel = input.webNovel,
                   let url = ReaderImageResolver.resolve(token: token, webNovel: webNovel) {
                    out += "![image](\(url))\n\n"
                } else {
                    out += "*[图片]*\n\n"
                }
            case .jump(_, _, let target):
                out += "*[跳转→第 \(target) 段]*\n\n"
            }
        }
        return out
    }

    // MARK: PDF (A4 595×842, 48pt margins)

    private static func buildPdf(_ input: ReaderExportInput) -> Data {
        let pageRect = CGRect(x: 0, y: 0, width: 595, height: 842)
        let margin: CGFloat = 48
        let contentRect = pageRect.insetBy(dx: margin, dy: margin)
        let renderer = UIGraphicsPDFRenderer(bounds: pageRect)

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineHeightMultiple = 1.55
        bodyStyle.firstLineHeadIndent = 24
        let bodyFont = UIFont(descriptor: UIFont.systemFont(ofSize: 12).fontDescriptor.withDesign(.serif) ?? UIFont.systemFont(ofSize: 12).fontDescriptor, size: 12)
        let bodyAttrs: [NSAttributedString.Key: Any] = [.font: bodyFont, .paragraphStyle: bodyStyle, .foregroundColor: UIColor.black]

        let chapterStyle = NSMutableParagraphStyle()
        chapterStyle.alignment = .center
        chapterStyle.paragraphSpacing = 18
        let chapterAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 18), .paragraphStyle: chapterStyle, .foregroundColor: UIColor.black,
        ]
        let metaStyle = NSMutableParagraphStyle()
        metaStyle.alignment = .center
        let metaAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: 10), .paragraphStyle: metaStyle, .foregroundColor: UIColor.darkGray,
        ]

        // Group content into per-page-start chunks: cover, then chapters.
        var chunks: [NSAttributedString] = []
        let current = NSMutableAttributedString()
        func flushChunk() {
            if current.length > 0 {
                chunks.append(current.copy() as! NSAttributedString)
                current.deleteCharacters(in: NSRange(location: 0, length: current.length))
            }
        }
        for token in input.tokens {
            switch token {
            case .chapter(_, _, let title):
                flushChunk()
                current.append(NSAttributedString(string: title + "\n", attributes: chapterAttrs))
            case .paragraph(_, _, let text, _, _):
                current.append(NSAttributedString(string: text + "\n", attributes: bodyAttrs))
            case .blankLine:
                current.append(NSAttributedString(string: "\n", attributes: bodyAttrs))
            case .pageBreak:
                flushChunk()
            case .pixivImage, .uploadedImage:
                current.append(NSAttributedString(string: "[图片]\n", attributes: metaAttrs))
            case .jump(_, _, let target):
                current.append(NSAttributedString(string: "[跳转→第 \(target) 段]\n", attributes: metaAttrs))
            }
        }
        flushChunk()

        return renderer.pdfData { ctx in
            // Cover page.
            ctx.beginPage()
            let titleStyle = NSMutableParagraphStyle()
            titleStyle.alignment = .center
            let title = NSAttributedString(string: input.title, attributes: [
                .font: UIFont.boldSystemFont(ofSize: 22), .paragraphStyle: titleStyle, .foregroundColor: UIColor.black,
            ])
            title.draw(in: CGRect(x: margin, y: 320, width: contentRect.width, height: 200))
            NSAttributedString(string: input.author, attributes: metaAttrs)
                .draw(in: CGRect(x: margin, y: 420, width: contentRect.width, height: 40))
            NSAttributedString(string: input.sourceURL, attributes: metaAttrs)
                .draw(in: CGRect(x: margin, y: 760, width: contentRect.width, height: 20))

            // Flow each chunk starting on a fresh page (CTFramesetter splits
            // anything longer than a page across pages).
            for chunk in chunks {
                let framesetter = CTFramesetterCreateWithAttributedString(chunk as CFAttributedString)
                var location = 0
                let total = chunk.length
                while location < total {
                    ctx.beginPage()
                    let path = CGPath(rect: contentRect, transform: nil)
                    let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: location, length: 0), path, nil)
                    ctx.cgContext.saveGState()
                    // Flip for CoreText.
                    ctx.cgContext.translateBy(x: 0, y: pageRect.height)
                    ctx.cgContext.scaleBy(x: 1, y: -1)
                    CTFrameDraw(frame, ctx.cgContext)
                    ctx.cgContext.restoreGState()
                    let visible = CTFrameGetVisibleStringRange(frame)
                    if visible.length == 0 { break }
                    location += visible.length
                }
            }
        }
    }

    // MARK: EPUB

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func buildEpub(_ input: ReaderExportInput) async throws -> Data {
        // Collect + download inline images (dedup by key; failures degrade
        // to placeholders like upstream).
        var imageData: [String: Data] = [:]
        var imageKeys: [Int: String] = [:] // token index → key
        for (i, token) in input.tokens.enumerated() {
            let key: String?
            switch token {
            case .pixivImage(_, _, let id, let page): key = "pixiv_\(id)_\(page)"
            case .uploadedImage(_, _, let id): key = "uploaded_\(id)"
            default: key = nil
            }
            guard let key else { continue }
            imageKeys[i] = key
            if imageData[key] != nil { continue }
            if let webNovel = input.webNovel,
               let urlString = ReaderImageResolver.resolve(token: token, webNovel: webNovel),
               let url = URL(string: urlString),
               let image = await PixivImageCache.shared.load(url),
               let jpeg = image.jpegData(compressionQuality: 0.85) {
                imageData[key] = jpeg
            }
        }

        // Build the single XHTML document with chapter anchors.
        var bodyHtml = "<h1>\(xmlEscape(input.title))</h1>\n"
        bodyHtml += "<p class=\"meta\">\(xmlEscape(input.author))</p>\n"
        var chapterAnchors: [(id: String, title: String)] = []
        for (i, token) in input.tokens.enumerated() {
            switch token {
            case .chapter(_, _, let title):
                let id = "c\(chapterAnchors.count + 1)"
                chapterAnchors.append((id, title))
                bodyHtml += "<h2 id=\"\(id)\">\(xmlEscape(title))</h2>\n"
            case .paragraph(_, _, let text, _, _):
                bodyHtml += "<p>\(xmlEscape(text))</p>\n"
            case .blankLine:
                bodyHtml += "<p class=\"blank\">&#160;</p>\n"
            case .pageBreak:
                bodyHtml += "<hr/>\n"
            case .pixivImage, .uploadedImage:
                if let key = imageKeys[i], imageData[key] != nil {
                    bodyHtml += "<p class=\"image\"><img src=\"images/\(key).jpg\" alt=\"\(key)\"/></p>\n"
                } else {
                    bodyHtml += "<p class=\"meta\"><em>[图片]</em></p>\n"
                }
            case .jump(_, _, let target):
                bodyHtml += "<p class=\"meta\"><em>[跳转→第 \(target) 段]</em></p>\n"
            }
        }

        let css = """
        body { font-family: serif; line-height: 1.7; padding: 1em; }
        h1 { text-align: center; }
        h2 { border-bottom: 1px solid #ccc; margin-top: 2em; }
        p { text-indent: 2em; margin: 0.5em 0; }
        p.meta { text-align: center; font-size: 0.9em; text-indent: 0; }
        p.blank { text-indent: 0; }
        p.image { text-align: center; text-indent: 0; }
        img { max-width: 100%; }
        hr { border: none; border-top: 1px dashed #999; margin: 2em 25%; }
        """

        let xhtml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>\(xmlEscape(input.title))</title><style type="text/css">\(css)</style></head>
        <body>\(bodyHtml)</body>
        </html>
        """

        let bookId = "shaft-novel-\(input.novelId)"
        var manifestItems = """
        <item id="content" href="content.xhtml" media-type="application/xhtml+xml"/>
        <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>
        """
        for key in imageData.keys.sorted() {
            manifestItems += "\n<item id=\"img_\(key)\" href=\"images/\(key).jpg\" media-type=\"image/jpeg\"/>"
        }

        let opf = """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
        <dc:title>\(xmlEscape(input.title))</dc:title>
        <dc:creator>\(xmlEscape(input.author))</dc:creator>
        <dc:language>zh</dc:language>
        <dc:identifier id="bookid">\(bookId)</dc:identifier>
        </metadata>
        <manifest>\(manifestItems)</manifest>
        <spine toc="ncx"><itemref idref="content"/></spine>
        </package>
        """

        var navPoints = ""
        if chapterAnchors.isEmpty {
            navPoints = """
            <navPoint id="n1" playOrder="1"><navLabel><text>\(xmlEscape(input.title))</text></navLabel><content src="content.xhtml"/></navPoint>
            """
        } else {
            for (i, anchor) in chapterAnchors.enumerated() {
                navPoints += """
                <navPoint id="n\(i + 1)" playOrder="\(i + 1)"><navLabel><text>\(xmlEscape(anchor.title))</text></navLabel><content src="content.xhtml#\(anchor.id)"/></navPoint>\n
                """
            }
        }

        let ncx = """
        <?xml version="1.0" encoding="UTF-8"?>
        <ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
        <head><meta name="dtb:uid" content="\(bookId)"/></head>
        <docTitle><text>\(xmlEscape(input.title))</text></docTitle>
        <navMap>\(navPoints)</navMap>
        </ncx>
        """

        let container = """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles>
        </container>
        """

        var zip = StoredZipWriter()
        zip.addEntry(name: "mimetype", data: Data("application/epub+zip".utf8))
        zip.addEntry(name: "META-INF/container.xml", data: Data(container.utf8))
        zip.addEntry(name: "OEBPS/content.opf", data: Data(opf.utf8))
        zip.addEntry(name: "OEBPS/toc.ncx", data: Data(ncx.utf8))
        zip.addEntry(name: "OEBPS/content.xhtml", data: Data(xhtml.utf8))
        for (key, data) in imageData.sorted(by: { $0.key < $1.key }) {
            zip.addEntry(name: "OEBPS/images/\(key).jpg", data: data)
        }
        return zip.finish()
    }
}

// MARK: - Minimal stored (uncompressed) ZIP writer

/// Just enough ZIP for EPUB: stored entries, CRC-32, central directory, EOCD.
struct StoredZipWriter {
    private var out = Data()
    private struct Entry {
        let name: Data
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }
    private var entries: [Entry] = []

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }

    private mutating func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    private mutating func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }

    mutating func addEntry(name: String, data: Data) {
        let nameData = Data(name.utf8)
        let crc = Self.crc32(data)
        let offset = UInt32(out.count)
        append32(0x04034B50)
        append16(20)            // version needed
        append16(0x0800)        // flags: UTF-8 names
        append16(0)             // method: stored
        append16(0)             // mod time
        append16(0)             // mod date
        append32(crc)
        append32(UInt32(data.count))
        append32(UInt32(data.count))
        append16(UInt16(nameData.count))
        append16(0)             // extra len
        out.append(nameData)
        out.append(data)
        entries.append(Entry(name: nameData, crc: crc, size: UInt32(data.count), offset: offset))
    }

    mutating func finish() -> Data {
        let centralStart = UInt32(out.count)
        for e in entries {
            append32(0x02014B50)
            append16(20)        // version made by
            append16(20)        // version needed
            append16(0x0800)
            append16(0)         // method
            append16(0)
            append16(0)
            append32(e.crc)
            append32(e.size)
            append32(e.size)
            append16(UInt16(e.name.count))
            append16(0)
            append16(0)         // comment len
            append16(0)         // disk start
            append16(0)         // internal attrs
            append32(0)         // external attrs
            append32(e.offset)
            out.append(e.name)
        }
        let centralSize = UInt32(out.count) - centralStart
        append32(0x06054B50)
        append16(0)
        append16(0)
        append16(UInt16(entries.count))
        append16(UInt16(entries.count))
        append32(centralSize)
        append32(centralStart)
        append16(0)
        return out
    }
}
