import SwiftUI
import UniformTypeIdentifiers

/// Decoding is a display operation. The session keeps the original Data/URL for
/// export, including BOMs and line endings, independently of this Unicode text.
enum ArtifactPlainText {
    enum Failure: Error, Equatable, Sendable {
        case unsupportedEncoding
        case invalidText
        var title: String {
            switch self {
            case .unsupportedEncoding: "Text Encoding Not Supported"
            case .invalidText: "Could Not Read Text"
            }
        }
        var message: String { "You can still save or share the original file to open it in another app." }
    }

    static func supports(filename: String, mimeType: String) -> Bool {
        let ext = (filename as NSString).pathExtension.lowercased()
        let mime = String(mimeType.split(separator: ";", maxSplits: 1).first ?? "").trimmingCharacters(in: .whitespaces).lowercased()
        if ["html", "htm", "xhtml", "rtf", "rtfd", "svg"].contains(ext) ||
            ["text/html", "application/xhtml+xml", "text/rtf", "application/rtf", "text/richtext", "text/enriched"].contains(mime) ||
            mime.hasPrefix("image/") || mime.hasPrefix("audio/") || mime.hasPrefix("video/") || mime == "application/pdf" { return false }
        if let type = UTType(filenameExtension: ext) {
            if [.image, .pdf, .audio, .movie, .archive].contains(where: { type.conforms(to: $0) }) { return false }
            if [.plainText, .sourceCode, .json, .xml, .commaSeparatedText, .tabSeparatedText].contains(where: { type.conforms(to: $0) }) { return true }
        }
        return ["txt", "text", "log", "md", "markdown", "yaml", "yml", "toml", "ini", "conf", "jsonl", "ndjson"].contains(ext) ||
            mime.hasPrefix("text/") || ["application/json", "application/xml", "application/yaml", "application/x-yaml"].contains(mime) ||
            mime.hasSuffix("+json") || mime.hasSuffix("+xml")
    }

    static func decode(_ data: Data, mimeType: String) -> Result<String, Failure> {
        let encoding: String.Encoding
        let skip: Int
        let unit: Int
        // UTF32 signatures precede UTF16: little-endian UTF32 shares FF FE.
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { encoding = .utf32LittleEndian; skip = 4; unit = 4 }
        else if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { encoding = .utf32BigEndian; skip = 4; unit = 4 }
        else if data.starts(with: [0xEF, 0xBB, 0xBF]) { encoding = .utf8; skip = 3; unit = 1 }
        else if data.starts(with: [0xFF, 0xFE]) { encoding = .utf16LittleEndian; skip = 2; unit = 2 }
        else if data.starts(with: [0xFE, 0xFF]) { encoding = .utf16BigEndian; skip = 2; unit = 2 }
        else {
            skip = 0
            switch charset(in: mimeType) {
            case nil, "utf-8", "utf8": encoding = .utf8; unit = 1
            case "us-ascii", "ascii": encoding = .ascii; unit = 1
            case "utf-16le", "utf16le": encoding = .utf16LittleEndian; unit = 2
            case "utf-16be", "utf16be": encoding = .utf16BigEndian; unit = 2
            case "utf-32le", "utf32le": encoding = .utf32LittleEndian; unit = 4
            case "utf-32be", "utf32be": encoding = .utf32BigEndian; unit = 4
            default: return .failure(.unsupportedEncoding)
            }
        }
        let payload = data.dropFirst(skip)
        guard payload.count % unit == 0, let text = String(data: payload, encoding: encoding),
              !text.unicodeScalars.contains(where: { $0.value == 0 }) else { return .failure(.invalidText) }
        return .success(text)
    }

    private static func charset(in mimeType: String) -> String? {
        for parameter in mimeType.split(separator: ";").dropFirst() {
            let pair = parameter.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if pair.count == 2, pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "charset" {
                return pair[1].trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'"))).lowercased()
            }
        }
        return nil
    }
}

struct ArtifactTextReader: UIViewRepresentable {
    let file: ArtifactPreviewFile
    func makeUIView(context: Context) -> ArtifactTextReaderView { ArtifactTextReaderView(file: file) }
    func updateUIView(_ view: ArtifactTextReaderView, context: Context) { view.show(file) }
}

/// One native text view and one file identity. Reflow never reassigns its text,
/// so selection and UIKit's text input positions stay attached to the document.
final class ArtifactTextReaderView: UIView {
    private let textView = ArtifactReadingTextView()
    private let unavailable = UIStackView()
    private let failureTitle = UILabel()
    private let failureMessage = UILabel()
    private var file: ArtifactPreviewFile?

    init(file: ArtifactPreviewFile) {
        super.init(frame: .zero)
        isAccessibilityElement = false
        backgroundColor = .clear; isOpaque = false
        textView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textView)
        NSLayoutConstraint.activate([
            textView.leadingAnchor.constraint(equalTo: leadingAnchor), textView.trailingAnchor.constraint(equalTo: trailingAnchor),
            textView.topAnchor.constraint(equalTo: topAnchor), textView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        unavailable.axis = .vertical; unavailable.alignment = .center; unavailable.spacing = 12
        failureTitle.font = .preferredFont(forTextStyle: .headline); failureTitle.numberOfLines = 0
        failureMessage.font = .preferredFont(forTextStyle: .body); failureMessage.numberOfLines = 0
        failureMessage.textColor = .secondaryLabel
        for label in [failureTitle, failureMessage] { label.adjustsFontForContentSizeCategory = true; label.textAlignment = .center }
        unavailable.addArrangedSubview(failureTitle); unavailable.addArrangedSubview(failureMessage)
        unavailable.translatesAutoresizingMaskIntoConstraints = false
        addSubview(unavailable)
        NSLayoutConstraint.activate([
            unavailable.centerYAnchor.constraint(equalTo: centerYAnchor),
            unavailable.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            unavailable.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24)
        ])
        show(file)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func show(_ file: ArtifactPreviewFile) {
        guard self.file !== file else { return }
        self.file = file // Retain the original private file through native reader lifetime.
        switch ArtifactPlainText.decode(file.data, mimeType: file.mimeType) {
        case .success(let text):
            unavailable.isHidden = true; textView.isHidden = false
            textView.install(text)
            accessibilityElements = [textView]
        case .failure(let failure):
            textView.isHidden = true; unavailable.isHidden = false
            failureTitle.text = failure.title; failureMessage.text = failure.message
            accessibilityElements = [failureTitle, failureMessage]
        }
    }
}

private final class ArtifactReadingTextView: UITextView {
    private struct Anchor {
        let position: Int
        let displacement: CGFloat
        let selection: NSRange
    }
    private var pendingAnchor: Anchor?
    private var lastAnchor: Anchor?
    private var lastSize = CGSize.zero
    private var lastFontSize: CGFloat = 0
    private var restoring = false

    init() {
        super.init(frame: .zero, textContainer: nil)
        isEditable = false; isSelectable = true
        dataDetectorTypes = []
        backgroundColor = .clear; isOpaque = false; textColor = .label
        font = .preferredFont(forTextStyle: .body); adjustsFontForContentSizeCategory = true
        textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 20, right: 20)
        textContainer.lineFragmentPadding = 0
        contentInsetAdjustmentBehavior = .never // The workspace already allocates safe reader bounds.
        alwaysBounceVertical = true
        accessibilityIdentifier = "artifact-text"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func install(_ value: String) {
        pendingAnchor = nil; lastAnchor = nil; lastSize = .zero
        text = value
        selectedRange = NSRange(location: 0, length: 0)
        setContentOffset(.zero, animated: false)
    }
    override var bounds: CGRect {
        willSet { if bounds.size != newValue.size { rememberAnchor() } }
    }
    override var frame: CGRect {
        willSet { if frame.size != newValue.size { rememberAnchor() } }
    }
    private func rememberAnchor() {
        guard !restoring, pendingAnchor == nil else { return }
        pendingAnchor = currentAnchor() ?? lastAnchor
    }
    private func currentAnchor() -> Anchor? {
        guard bounds.width > 0, bounds.height > 0, !text.isEmpty,
              let position = closestPosition(to: CGPoint(x: bounds.minX + textContainerInset.left + 1,
                                                         y: bounds.minY + adjustedContentInset.top + 1)) else { return nil }
        let rect = caretRect(for: position)
        guard rect.minY.isFinite else { return nil }
        return Anchor(position: offset(from: beginningOfDocument, to: position),
                      displacement: rect.minY - contentOffset.y - adjustedContentInset.top, selection: selectedRange)
    }
    override func layoutSubviews() {
        if !restoring, pendingAnchor == nil, lastSize != .zero,
           (lastSize != bounds.size || lastFontSize != font?.pointSize) { pendingAnchor = lastAnchor }
        super.layoutSubviews()
        if let anchor = pendingAnchor, let manager = textLayoutManager,
           let content = manager.textContentManager,
           let end = content.location(content.documentRange.location, offsetBy: min(anchor.position + 1, text.utf16.count)),
           let prefix = NSTextRange(location: content.documentRange.location, end: end) {
            // Resolve estimated fragments before the visible position. A raw
            // pixel offset belongs to the old wrapping width, not the passage.
            manager.ensureLayout(for: prefix)
        }
        if !restoring, let anchor = pendingAnchor, bounds.width > 0, bounds.height > 0 {
            pendingAnchor = nil
            restoring = true
            if selectedRange != anchor.selection { selectedRange = anchor.selection }
            if let position = position(from: beginningOfDocument, offset: min(anchor.position, text.utf16.count)) {
                let y = caretRect(for: position).minY - anchor.displacement - adjustedContentInset.top
                let minimum = -adjustedContentInset.top
                let maximum = max(minimum, contentSize.height - bounds.height + adjustedContentInset.bottom)
                setContentOffset(CGPoint(x: contentOffset.x, y: min(maximum, max(minimum, y))), animated: false)
            }
            restoring = false
        }
        lastSize = bounds.size; lastFontSize = font?.pointSize ?? 0
        if !restoring { lastAnchor = currentAnchor() }
    }
}
