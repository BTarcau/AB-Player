import Foundation
import PDFKit
import UIKit

enum BookParseError: LocalizedError {
    case unreadable, noText, drm
    var errorDescription: String? {
        switch self {
        case .unreadable: return "That file couldn't be opened as an EPUB or PDF."
        case .noText: return "No readable text was found in that book. Scanned PDFs (pictures of pages) can't be read aloud."
        case .drm: return "That EPUB is DRM-protected, so its text is encrypted and can't be read."
        }
    }
}

// MARK: - EPUB

/// Turns an EPUB into chapters of sentences, with title, author, subjects,
/// series and cover. Ported from Lamplight's book.js.
enum EPUBParser {
    static func parse(_ data: Data) throws -> ParsedText {
        let zip = try ZipReader(data: data)
        if zip.entry("META-INF/encryption.xml") != nil,
           let enc = try? zip.string("META-INF/encryption.xml"), enc.contains("EncryptedData"),
           !enc.contains("http://www.idpf.org/2008/embedding"), !enc.contains("http://ns.adobe.com/pdf/enc#RC") {
            throw BookParseError.drm
        }
        guard let container = try zip.string("META-INF/container.xml"),
              let opfPath = firstMatch(container, #"full-path\s*=\s*"([^"]+)""#)
        else { throw BookParseError.unreadable }
        let opfDir = opfPath.contains("/") ? String(opfPath[...opfPath.lastIndex(of: "/")!]) : ""
        guard let opfXML = try zip.read(opfPath) else { throw BookParseError.unreadable }
        let opf = OPFDelegate()
        let p = XMLParser(data: opfXML)
        p.delegate = opf
        p.parse()

        var files: [(path: String, paragraphs: [String], heading: String?)] = []
        for idref in opf.spine {
            guard let item = opf.manifest[idref] else { continue }
            let path = resolve(opfDir, item.href)
            guard let xml = try? zip.read(path) else { continue }
            let (paragraphs, heading) = extractText(xml)
            guard !paragraphs.isEmpty else { continue }
            files.append((path, paragraphs, heading))
        }
        let toc = titlesByFile(loadTOC(zip: zip, opf: opf, opfDir: opfDir), readingOrder: files.map(\.path),
                               openings: files.map { Array($0.paragraphs.prefix(8)) })

        // Chapters follow the contents, not the files: one chapter is often split
        // across several files, and a file with no contents entry continues the
        // chapter before it.
        var groups: [(title: String, paragraphs: [String])] = []
        for (path, paragraphs, heading) in files {
            if let title = toc[path] {
                groups.append((title, []))
            } else if groups.isEmpty {
                groups.append((heading ?? "Front Matter", []))
            }
            groups[groups.count - 1].paragraphs += paragraphs
        }
        let chapters = groups.compactMap { TextChapter(title: $0.title, paragraphs: $0.paragraphs) }
        guard !chapters.isEmpty else { throw BookParseError.noText }

        var parsed = ParsedText(chapters: chapters)
        parsed.title = opf.title
        parsed.author = opf.creator
        parsed.subjects = opf.subjects

        // Series: Calibre's meta, or EPUB 3 belongs-to-collection.
        let byName = { (name: String) in opf.metas.first { ($0["name"] ?? "").lowercased() == name }?["content"]?.trimmingCharacters(in: .whitespaces) ?? "" }
        parsed.series = byName("calibre:series")
        parsed.seriesIndex = Double(byName("calibre:series_index"))
        if parsed.series.isEmpty, let coll = opf.metas.first(where: { $0["property"] == "belongs-to-collection" }) {
            let id = coll["id"] ?? ""
            let refine = { (prop: String) in opf.metas.first { $0["refines"] == "#" + id && $0["property"] == prop }?["#text"] ?? "" }
            let type = refine("collection-type")
            if type.isEmpty || type == "series" {
                parsed.series = coll["#text"] ?? ""
                parsed.seriesIndex = Double(refine("group-position"))
            }
        }

        // Cover: properties="cover-image" (EPUB 3), <meta name="cover"> (EPUB 2), or an image named cover.
        var coverItem = opf.manifest.values.first { $0.properties.split(separator: " ").contains("cover-image") }
        if coverItem == nil, let id = opf.metas.first(where: { ($0["name"] ?? "").lowercased() == "cover" })?["content"] {
            coverItem = opf.manifest[id]
        }
        if coverItem == nil {
            coverItem = opf.manifest.values.first { $0.mediaType.hasPrefix("image/") && $0.href.lowercased().contains("cover") }
        }
        if let item = coverItem, let bytes = try? zip.read(resolve(opfDir, item.href)), bytes.count < 4_000_000, UIImage(data: bytes) != nil {
            parsed.cover = bytes
        }
        return parsed
    }

    // MARK: Contents

    /// Contents entries in contents order, one per file (its first), as (resolved path, title),
    /// from nav.xhtml (EPUB 3) or toc.ncx (EPUB 2).
    private static func loadTOC(zip: ZipReader, opf: OPFDelegate, opfDir: String) -> [(path: String, title: String)] {
        var map: [(path: String, title: String)] = []
        var seen = Set<String>()
        func add(_ entries: [(String, String)], dir: String) {
            for (href, title) in entries where !title.isEmpty {
                let path = resolve(dir, href)
                if seen.insert(path).inserted { map.append((path, title)) }
            }
        }
        if let nav = opf.manifest.values.first(where: { $0.properties.split(separator: " ").contains("nav") }),
           let xml = try? zip.read(opfDir + nav.href) {
            let d = TOCDelegate(ncx: false)
            let parser = XMLParser(data: cleanEntities(xml))
            parser.delegate = d
            parser.parse()
            add(d.result, dir: directory(of: opfDir + nav.href))
        }
        if map.isEmpty {
            let ncxHref = opf.spineTOC.flatMap { opf.manifest[$0]?.href }
                ?? opf.manifest.values.first { $0.href.lowercased().hasSuffix(".ncx") }?.href
            if let ncxHref, let xml = try? zip.read(opfDir + ncxHref) {
                let d = TOCDelegate(ncx: true)
                let parser = XMLParser(data: xml)
                parser.delegate = d
                parser.parse()
                add(d.result, dir: directory(of: opfDir + ncxHref))
            }
        }
        return map
    }

    /// File path -> chapter title. Contents entries normally run in reading order;
    /// one that points backwards is a mistake in the book (e.g. a chapter linked to
    /// the printed contents page), so it is dropped, and its title goes to an
    /// untitled file in the gap where it belongs whose first lines show that title.
    static func titlesByFile(_ entries: [(path: String, title: String)], readingOrder: [String],
                             openings: [[String]]) -> [String: String] {
        let position = Dictionary(readingOrder.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        let placed = entries.compactMap { e in position[e.path].map { (e.title, $0) } }
        guard !placed.isEmpty else { return [:] }

        // The longest run of entries in reading order is kept (ties keep the earlier ones).
        var length = [Int](repeating: 1, count: placed.count)
        var prev = [Int](repeating: -1, count: placed.count)
        for i in placed.indices {
            for j in 0..<i where placed[j].1 < placed[i].1 && length[j] + 1 > length[i] {
                length[i] = length[j] + 1
                prev[i] = j
            }
        }
        var keep = Set<Int>()
        var i = length.firstIndex(of: length.max()!)!
        while i >= 0 { keep.insert(i); i = prev[i] }

        var titles: [String: String] = [:]
        for k in keep { titles[readingOrder[placed[k].1]] = placed[k].0 }
        var k = 0
        while k < placed.count {
            guard !keep.contains(k) else { k += 1; continue }
            // A run of dropped entries between two kept ones.
            var end = k
            while end + 1 < placed.count && !keep.contains(end + 1) { end += 1 }
            let lo = (0..<k).last { keep.contains($0) }.map { placed[$0].1 } ?? -1
            let hi = (end + 1 < placed.count) ? placed[end + 1].1 : readingOrder.count
            for d in k...end {
                let want = simplified(placed[d].0)
                if let slot = ((lo + 1)..<hi).first(where: { f in
                    titles[readingOrder[f]] == nil && openings[f].contains { simplified($0) == want }
                }) {
                    titles[readingOrder[slot]] = placed[d].0
                }
            }
            k = end + 1
        }
        return titles
    }

    /// Lowercased letters and digits only, for comparing titles.
    private static func simplified(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: Chapter text

    /// Paragraphs of a content file, and its first heading.
    static func extractText(_ xml: Data) -> ([String], String?) {
        let d = ContentDelegate()
        let parser = XMLParser(data: cleanEntities(xml))
        parser.delegate = d
        if parser.parse() || !d.paragraphs.isEmpty { return (d.paragraphs, d.heading) }
        // Not well-formed XML (some EPUB 2 files are plain HTML): split on block tags instead.
        let html = String(data: xml, encoding: .utf8) ?? String(decoding: xml, as: UTF8.self)
        return (looseHTMLParagraphs(html), nil)
    }

    private static func looseHTMLParagraphs(_ html: String) -> [String] {
        var s = html.replacingOccurrences(of: #"(?is)<(head|script|style)\b.*?</\1>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<br\s*/?>"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</?(p|div|li|h[1-6]|blockquote|tr|section)\b[^>]*>"#, with: "\u{1E}", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return s.components(separatedBy: "\u{1E}")
            .map { decodeEntities($0).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: Paths and entities

    static func directory(of path: String) -> String {
        path.contains("/") ? String(path[...path.lastIndex(of: "/")!]) : ""
    }

    /// Resolves an href against a directory inside the EPUB ("../Text/ch1.xhtml#x").
    static func resolve(_ baseDir: String, _ href: String) -> String {
        let clean = String(href.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? "")
        let decoded = clean.removingPercentEncoding ?? clean
        var parts = baseDir.split(separator: "/").map(String.init)
        if decoded.hasPrefix("/") { parts = [] }
        for comp in decoded.split(separator: "/").map(String.init) {
            if comp == "." || comp.isEmpty { continue }
            if comp == ".." { if !parts.isEmpty { parts.removeLast() } } else { parts.append(comp) }
        }
        return parts.joined(separator: "/")
    }

    private static func firstMatch(_ text: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 1), in: text) else { return nil }
        return String(text[r])
    }

    private static let namedEntities: [String: String] = [
        "nbsp": "\u{A0}", "mdash": "—", "ndash": "–", "hellip": "…", "lsquo": "‘", "rsquo": "’",
        "ldquo": "“", "rdquo": "”", "sbquo": "‚", "bdquo": "„", "copy": "©", "reg": "®", "trade": "™",
        "eacute": "é", "egrave": "è", "ecirc": "ê", "euml": "ë", "aacute": "á", "agrave": "à", "acirc": "â",
        "auml": "ä", "aring": "å", "ccedil": "ç", "iacute": "í", "igrave": "ì", "icirc": "î", "iuml": "ï",
        "oacute": "ó", "ograve": "ò", "ocirc": "ô", "ouml": "ö", "uacute": "ú", "ugrave": "ù", "ucirc": "û",
        "uuml": "ü", "ntilde": "ñ", "szlig": "ß", "aelig": "æ", "oelig": "œ", "Eacute": "É", "Aacute": "Á",
        "laquo": "«", "raquo": "»", "middot": "·", "bull": "•", "shy": "", "thinsp": " ", "ensp": " ",
        "emsp": " ", "zwj": "", "zwnj": "", "deg": "°", "frac12": "½", "frac14": "¼", "frac34": "¾",
        "times": "×", "sect": "§", "para": "¶", "dagger": "†", "Dagger": "‡", "prime": "′", "Prime": "″",
        "pound": "£", "euro": "€", "cent": "¢", "yen": "¥", "iexcl": "¡", "iquest": "¿",
    ]

    /// XMLParser only knows the five XML entities; swap HTML ones for their characters.
    static func cleanEntities(_ data: Data) -> Data {
        guard var s = String(data: data, encoding: .utf8) else { return data }
        guard s.contains("&") else { return data }
        let re = try! NSRegularExpression(pattern: "&([A-Za-z][A-Za-z0-9]*);")
        let ns = NSMutableString(string: s)
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)).reversed() {
            let name = ns.substring(with: m.range(at: 1))
            if ["amp", "lt", "gt", "quot", "apos"].contains(name) { continue }
            ns.replaceCharacters(in: m.range, with: namedEntities[name] ?? " ")
        }
        s = ns as String
        return Data(s.utf8)
    }

    static func decodeEntities(_ s: String) -> String {
        var out = s
        for (name, value) in namedEntities { out = out.replacingOccurrences(of: "&\(name);", with: value) }
        out = out.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
        return out
    }
}

private func localName(_ name: String) -> String {
    (name.split(separator: ":").last.map(String.init) ?? name).lowercased()
}

private final class OPFDelegate: NSObject, XMLParserDelegate {
    struct Item { var href: String; var mediaType: String; var properties: String }
    var manifest: [String: Item] = [:]
    var spine: [String] = []
    var spineTOC: String?
    var title = ""
    var creator = ""
    var subjects: [String] = []
    /// Every <meta>: its attributes plus "#text" for its content.
    var metas: [[String: String]] = []
    private var text = ""
    private var openMeta: [String: String]?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        text = ""
        switch localName(elementName) {
        case "item":
            if let id = attributes["id"], let href = attributes["href"] {
                manifest[id] = Item(href: href, mediaType: attributes["media-type"] ?? "", properties: attributes["properties"] ?? "")
            }
        case "itemref": if let id = attributes["idref"] { spine.append(id) }
        case "spine": spineTOC = attributes["toc"]
        case "meta": openMeta = attributes
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let t = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        switch localName(elementName) {
        case "title": if title.isEmpty { title = t }
        case "creator": if creator.isEmpty { creator = t }
        case "subject": if !t.isEmpty { subjects.append(t) }
        case "meta":
            var m = openMeta ?? [:]
            m["#text"] = t
            metas.append(m)
            openMeta = nil
        default: break
        }
        text = ""
    }
}

private final class TOCDelegate: NSObject, XMLParserDelegate {
    let ncx: Bool
    init(ncx: Bool) { self.ncx = ncx }
    // nav documents: entries per <nav>, so the "toc" one can be preferred.
    private var navs: [(isTOC: Bool, entries: [(String, String)])] = []
    private var navDepth = 0
    private var href: String?
    private var text = ""
    // ncx
    private var label = ""
    private var inLabel = false
    private var ncxEntries: [(String, String)] = []

    var result: [(String, String)] {
        if ncx { return ncxEntries }
        return (navs.first { $0.isTOC } ?? navs.first)?.entries ?? []
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        let n = localName(elementName)
        if ncx {
            if n == "navlabel" { inLabel = true; label = "" }
            if n == "content", let src = attributes["src"] {
                ncxEntries.append((src, label.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)))
            }
            return
        }
        if n == "nav" {
            navDepth += 1
            let type = (attributes["epub:type"] ?? attributes["type"] ?? "").lowercased()
            navs.append((type.contains("toc"), []))
        } else if n == "br", href != nil {
            text += " "
        } else if n == "a", navDepth > 0, let h = attributes["href"] {
            href = h
            text = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if ncx { if inLabel { label += string } } else if href != nil { text += string }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let n = localName(elementName)
        if ncx { if n == "navlabel" { inLabel = false }; return }
        if n == "a", let h = href {
            let t = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, !navs.isEmpty { navs[navs.count - 1].entries.append((h, t)) }
            href = nil
        } else if n == "nav" {
            navDepth -= 1
        }
    }
}

/// Collects a content file's text as paragraphs: every block element boundary
/// starts a new paragraph. Hidden elements, scripts and page-number markers are skipped.
private final class ContentDelegate: NSObject, XMLParserDelegate {
    static let blocks: Set<String> = ["p", "li", "blockquote", "h1", "h2", "h3", "h4", "h5", "h6", "div", "section", "article", "tr", "dt", "dd", "pre", "figcaption", "aside", "header", "footer"]
    var paragraphs: [String] = []
    var heading: String?
    private var buffer = ""
    private var skipDepth = 0
    private var headingBuffer: String?

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes: [String: String] = [:]) {
        if skipDepth > 0 { skipDepth += 1; return }
        let n = localName(elementName)
        let style = (attributes["style"] ?? "").lowercased().replacingOccurrences(of: " ", with: "")
        let epubType = (attributes["epub:type"] ?? "").lowercased()
        if ["head", "script", "style", "title"].contains(n) || attributes["hidden"] != nil
            || attributes["aria-hidden"] == "true" || style.contains("display:none") || epubType.contains("pagebreak") {
            skipDepth = 1
            return
        }
        if n == "br" { buffer += " " }
        if Self.blocks.contains(n) { flush() }
        if heading == nil, ["h1", "h2", "h3"].contains(n) { headingBuffer = "" }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard skipDepth == 0 else { return }
        buffer += string
        headingBuffer? += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if skipDepth > 0 { skipDepth -= 1; return }
        let n = localName(elementName)
        if Self.blocks.contains(n) { flush() }
        if let h = headingBuffer, ["h1", "h2", "h3"].contains(n) {
            let t = h.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { heading = t }
            headingBuffer = nil
        }
    }

    func parserDidEndDocument(_ parser: XMLParser) { flush() }
    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) { flush() }

    private func flush() {
        let t = buffer.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { paragraphs.append(t) }
        buffer = ""
    }
}

// MARK: - PDF

/// Chapters from the PDF's outline (bookmarks) when it has one, otherwise every
/// 8 pages. Paragraph breaks are guessed from line spacing.
enum PDFTextParser {
    static func parse(url: URL) throws -> ParsedText {
        guard let doc = PDFDocument(url: url) else { throw BookParseError.unreadable }
        if doc.isEncrypted && doc.isLocked { throw BookParseError.drm }
        var plans: [(title: String, start: Int, end: Int)] = []

        if var root = doc.outlineRoot {
            // Unwrap a single root bookmark named after the book.
            while root.numberOfChildren == 1, let only = root.child(at: 0), only.numberOfChildren > 0 { root = only }
            var resolved: [(String, Int)] = []
            for i in 0..<root.numberOfChildren {
                guard let item = root.child(at: i), let page = item.destination?.page ?? (item.action as? PDFActionGoTo)?.destination.page else { continue }
                let title = (item.label ?? "").replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
                if !title.isEmpty { resolved.append((title, doc.index(for: page))) }
            }
            resolved.sort { $0.1 < $1.1 }
            let deduped = resolved.enumerated().filter { $0.offset == 0 || $0.element.1 != resolved[$0.offset - 1].1 }.map(\.element)
            for (i, r) in deduped.enumerated() {
                let end = i + 1 < deduped.count ? deduped[i + 1].1 - 1 : doc.pageCount - 1
                plans.append((r.0, r.1, max(r.1, end)))
            }
            if let first = plans.first, first.start > 0 { plans.insert(("Front Matter", 0, first.start - 1), at: 0) }
        }
        if plans.isEmpty {
            var start = 0
            while start < doc.pageCount {
                let end = min(doc.pageCount - 1, start + 7)
                plans.append((start == end ? "Page \(start + 1)" : "Pages \(start + 1)–\(end + 1)", start, end))
                start = end + 1
            }
        }

        var chapters: [TextChapter] = []
        for plan in plans {
            var paras: [String] = []
            for i in plan.start...plan.end { if let page = doc.page(at: i) { paras += paragraphs(page) } }
            if let ch = TextChapter(title: plan.title, paragraphs: paras) { chapters.append(ch) }
        }
        guard !chapters.isEmpty else { throw BookParseError.noText }

        var parsed = ParsedText(chapters: chapters)
        let attrs = doc.documentAttributes ?? [:]
        parsed.title = (attrs[PDFDocumentAttribute.titleAttribute] as? String ?? "").trimmingCharacters(in: .whitespaces)
        parsed.author = (attrs[PDFDocumentAttribute.authorAttribute] as? String ?? "").trimmingCharacters(in: .whitespaces)
        if let subject = attrs[PDFDocumentAttribute.subjectAttribute] as? String, !subject.isEmpty { parsed.subjects = [subject] }
        if let first = doc.page(at: 0) {
            parsed.cover = first.thumbnail(of: CGSize(width: 600, height: 800), for: .mediaBox).jpegData(compressionQuality: 0.85)
        }
        return parsed
    }

    /// Lines grouped into paragraphs wherever the gap is well over the page's usual spacing.
    static func paragraphs(_ page: PDFPage) -> [String] {
        let lines: [(text: String, y: CGFloat)] = (page.selection(for: page.bounds(for: .mediaBox))?.selectionsByLine() ?? [])
            .compactMap { sel in
                let t = (sel.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : (t, sel.bounds(for: page).minY)
            }
        if lines.isEmpty {
            return (page.string ?? "").components(separatedBy: "\n\n").map {
                $0.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            }.filter { !$0.isEmpty }
        }
        let gaps = zip(lines, lines.dropFirst()).map { abs($0.y - $1.y) }.sorted()
        let median = gaps.isEmpty ? 14 : gaps[gaps.count / 2]
        var paras: [String] = []
        var current = ""
        for (i, line) in lines.enumerated() {
            if i > 0, abs(lines[i - 1].y - line.y) > median * 1.6, !current.isEmpty {
                paras.append(current)
                current = ""
            }
            if current.hasSuffix("-"), let f = line.text.first, f.isLowercase {
                current.removeLast()          // re-join a word hyphenated across lines
                current += line.text
            } else {
                current = current.isEmpty ? line.text : current + " " + line.text
            }
        }
        if !current.isEmpty { paras.append(current) }
        return paras
    }
}
