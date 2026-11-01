import Foundation
import UniformTypeIdentifiers

/// A transcript-derived item, scoped to one chat by its caller. Discovery never grants file access.
public struct DiscoveredArtifact: Identifiable, Equatable, Sendable {
    public struct ID: Hashable, Sendable {
        fileprivate enum Content: Hashable, Sendable {
            case file(Data)
            case inline(offset: Int, format: String, source: Data)
        }
        fileprivate let message: Data
        fileprivate let content: Content
    }

    public enum Category: String, CaseIterable, Sendable { case output, reference }
    public enum Kind: String, CaseIterable, Sendable { case image, document, audio, video, preview }
    public enum Payload: Equatable, Sendable {
        case file(ChatAttachment)
        case inline(ReplyContent.Block)
    }

    public let id: ID
    public let messageID: String
    public let timestamp: Date?
    public let title: String
    public let category: Category
    public let payload: Payload

    public var attachment: ChatAttachment? {
        if case .file(let attachment) = payload { return attachment }
        return nil
    }
    public var block: ReplyContent.Block? {
        if case .inline(let block) = payload { return block }
        return nil
    }
    public var kind: Kind {
        guard let attachment else { return .preview }
        let mime = attachment.mimeType == "application/octet-stream"
            ? UTType(filenameExtension: (attachment.path as NSString).pathExtension)?.preferredMIMEType ?? attachment.mimeType
            : attachment.mimeType
        if mime.hasPrefix("image/") { return .image }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("video/") { return .video }
        return .document
    }
    public var searchableText: String {
        switch payload {
        case .file(let attachment): title + "\n" + attachment.path
        case .inline(let block): title + "\n" + block.source
        }
    }
}

public enum ArtifactDiscovery {
    public static func artifacts(in messages: [ChatMessage]) -> [DiscoveredArtifact] {
        var files: [Data: DiscoveredArtifact] = [:]
        var suppliedMetadata = Set<Data>()
        var order: [Data] = []
        var previews: [DiscoveredArtifact] = []
        func add(_ attachment: ChatAttachment, from message: ChatMessage, category: DiscoveredArtifact.Category,
                 supplied: Bool = false) {
            let path = Data(attachment.path.utf8)
            guard !path.isEmpty else { return }
            if let previous = files[path] {
                if previous.category == .output && category == .reference { return }
                if previous.category == category {
                    if let oldDate = previous.timestamp, let newDate = message.timestamp, newDate < oldDate { return }
                    if Data(previous.messageID.utf8) == Data(message.id.utf8), suppliedMetadata.contains(path), !supplied { return }
                }
            }
            if files[path] == nil { order.append(path) }
            if supplied { suppliedMetadata.insert(path) } else { suppliedMetadata.remove(path) }
            files[path] = DiscoveredArtifact(id: .init(message: Data(message.id.utf8), content: .file(path)),
                messageID: message.id, timestamp: message.timestamp, title: attachment.name,
                category: category, payload: .file(attachment))
        }
        for message in messages {
            guard message.isVisible, message.displayKind != "hidden", message.isSilent != true,
                  !HermesMessagePresentation.isMachinery(message.displayKind) || message.botSender != nil else { continue }
            if message.role == .tool {
                for attachment in generatedFiles(in: message) { add(attachment, from: message, category: .output) }
                continue
            }
            guard message.role == .assistant || message.role == .user else { continue }
            for attachment in message.attachments {
                add(attachment, from: message, category: message.role == .assistant ? .output : .reference, supplied: true)
            }
            if message.role == .user {
                let suppliedPaths = Set(message.attachments.map { Data($0.path.utf8) })
                for attachment in AttachmentPresentation.display(message).attachments
                    where !suppliedPaths.contains(Data(attachment.path.utf8)) {
                    add(attachment, from: message, category: .reference, supplied: true)
                }
            }
            guard message.role == .assistant else { continue }
            for block in ReplyContent(message: message).blocks {
                switch block.kind {
                case .text:
                    for part in ArtifactReferences.parts(in: block.source) {
                        if case .attachment(let attachment, let provenance) = part {
                            add(attachment, from: message, category: provenance == .delivered ? .output : .reference)
                        }
                    }
                case .filePreview(let reference):
                    if block.isComplete { add(reference.attachment, from: message, category: .output) }
                case .preview(let format):
                    guard block.isComplete else { continue }
                    let title: String
                    switch format {
                    case .html: title = "HTML preview"
                    case .svg: title = "SVG illustration"
                    case .mermaid: title = "Mermaid diagram"
                    }
                    previews.append(DiscoveredArtifact(id: .init(message: Data(message.id.utf8),
                        content: .inline(offset: block.id, format: format.rawValue, source: Data(block.source.utf8))),
                        messageID: message.id, timestamp: message.timestamp, title: title,
                        category: .output, payload: .inline(block)))
                case .code: continue
                }
            }
        }
        return order.compactMap { files[$0] } + previews
    }

    private static let readOnlyTools: Set<String> = [
        "read_file", "file_read", "read_text_file", "read_media_file", "list_files", "search_files"
    ]
    private static let outputKeys: Set<String> = [
        "generated_file", "generated_path", "output_file", "output_path", "saved_to", "artifact_path"
    ]
    private static let resultKeys: Set<String> = ["result", "results", "output", "outputs", "data", "artifacts", "files"]

    private static func failed(_ fields: [String: HermesJSON]) -> Bool {
        fields["success"]?.flag == false || fields["ok"]?.flag == false ||
            fields["is_error"]?.flag == true || fields["error"]?.nonempty != nil ||
            ["error", "failed", "failure"].contains(fields["status"]?.text?.lowercased() ?? "") ||
            fields["exit_code"]?.integer.map({ $0 != 0 }) == true
    }

    private static func generatedFiles(in message: ChatMessage) -> [ChatAttachment] {
        let value = try? HermesJSON.decode(Data(message.text.utf8))
        var files: [ChatAttachment] = []
        if message.toolName?.lowercased() == "terminal" {
            func deliveries(in text: String) -> [ChatAttachment] {
                ArtifactReferences.parts(in: text).compactMap { part in
                    if case .attachment(let attachment, .delivered) = part { return attachment }
                    return nil
                }
            }
            func collect(_ value: HermesJSON) -> [ChatAttachment] {
                if let text = value.text { return deliveries(in: text) }
                guard let fields = value.fields,
                      !failed(fields) else { return [] }
                return ["output", "stdout"].flatMap { key in
                    fields[key].map(collect) ?? []
                }
            }
            guard let value else { return deliveries(in: message.text) }
            files += collect(value)
        }
        guard !readOnlyTools.contains(message.toolName?.lowercased() ?? ""),
              let value else { return [] }
        func collect(_ value: HermesJSON) {
            switch value {
            case .object(let fields):
                guard !failed(fields) else { return }
                for key in fields.keys.sorted() {
                    guard let child = fields[key] else { continue }
                    if outputKeys.contains(key.lowercased()), let raw = child.text,
                       let path = ArtifactReferences.localPath(raw, relative: true, bareRelative: true) {
                        files.append(ArtifactReferences.attachment(path: path))
                    } else if resultKeys.contains(key.lowercased()) { collect(child) }
                }
            case .array(let values):
                for child in values { collect(child) }
            default: break
            }
        }
        collect(value)
        return files
    }
}
