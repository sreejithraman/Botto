import SwiftUI
import BottoCore

/// Owns the native input, not its draft. The Binding retains the workspace's
/// captured-owner fence; the native view owns editing/composition and selection.
struct NativeComposerEditor: UIViewRepresentable {
    struct Identity: Equatable {
        let owner: PresentationOwner
        let viewLifetime: UUID
        let revision: UUID
    }
    @Binding var text: String
    let identity: Identity?
    let enabled: Bool
    let placeholder: String
    let accessibilityLabel: String
    let editing: ComposerEditingHandle
    let canEdit: () -> Bool

    func makeUIView(context: Context) -> NativeComposerTextView {
        let view = NativeComposerTextView()
        editing.editor = view; view.editingHandle = editing
        return view
    }
    func updateUIView(_ view: NativeComposerTextView, context: Context) {
        view.configure(text: $text, identity: identity, enabled: enabled, placeholder: placeholder,
            label: accessibilityLabel, dynamicType: context.environment.dynamicTypeSize,
            direction: context.environment.layoutDirection, canEdit: canEdit)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: NativeComposerTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        return uiView.fittingSize(width: width)
    }
    static func dismantleUIView(_ view: NativeComposerTextView, coordinator: ()) { view.retire() }
}

/// One weak cancellation entry point; all editing intent stays on the actual
/// control. Old views cannot unregister a replacement control.
@MainActor final class ComposerEditingHandle {
    weak var editor: NativeComposerTextView?
    func cancel() { editor?.cancelEditing() }
    func commit() { editor?.commitComposition() }
}
private struct ComposerEditingKey: EnvironmentKey { static let defaultValue: ComposerEditingHandle? = nil }
extension EnvironmentValues {
    var composerEditing: ComposerEditingHandle? {
        get { self[ComposerEditingKey.self] }
        set { self[ComposerEditingKey.self] = newValue }
    }
}

final class NativeComposerTextView: UITextView, UITextViewDelegate {
    private var identity: NativeComposerEditor.Identity?
    private var boundText = Binding.constant("")
    private var publishingDraft: NativeComposerEditor.Identity?
    private var canEdit: () -> Bool = { false }
    private var eligible = false
    private var reconciling = false
    private let prompt = UILabel()
    private var maximumLines = 6
    #if DEBUG
    private lazy var inputTrace = InteractionFrameTrace.make(viewport: self, outputVariable: "BOTTO_TYPING_TRACE_OUTPUT")
    #endif
    weak var editingHandle: ComposerEditingHandle?

    init() {
        super.init(frame: .zero, textContainer: nil)
        delegate = self
        backgroundColor = .clear; isOpaque = false; textColor = .label
        textContainer.lineFragmentPadding = 0
        textContainerInset = UIEdgeInsets(top: 14, left: 16, bottom: 14, right: 0)
        contentInsetAdjustmentBehavior = .never
        font = .preferredFont(forTextStyle: .body); adjustsFontForContentSizeCategory = true
        isScrollEnabled = true; showsHorizontalScrollIndicator = false
        autocorrectionType = .default; autocapitalizationType = .sentences
        returnKeyType = .default; enablesReturnKeyAutomatically = false
        allowsEditingTextAttributes = false
        accessibilityIdentifier = "chat-composer"
        prompt.textColor = .placeholderText; prompt.isAccessibilityElement = false
        prompt.adjustsFontForContentSizeCategory = true
        addSubview(prompt)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(text binding: Binding<String>, identity nextIdentity: NativeComposerEditor.Identity?, enabled: Bool,
                   placeholder: String, label: String, dynamicType: DynamicTypeSize,
                   direction: LayoutDirection = .leftToRight, canEdit: @escaping () -> Bool) {
        let replaced = identity != nextIdentity
        var geometryChanged = replaced || markedTextRange != nil
        if replaced {
            // End the old composition with writes suppressed BEFORE installing
            // the new Binding. Native undo cannot cross a task/semantic boundary.
            reconciling = true
            cancelEditing(commit: false)
            unmarkText(); undoManager?.removeAllActions()
            reconciling = false
        }
        identity = nextIdentity; boundText = binding; self.canEdit = canEdit
        eligible = enabled && nextIdentity != nil
        if !eligible { cancelEditing() }
        if isEditable != eligible { isEditable = eligible; geometryChanged = true }
        if isSelectable != eligible { isSelectable = eligible; geometryChanged = true }
        if isUserInteractionEnabled != eligible { isUserInteractionEnabled = eligible }
        let nextMaximumLines = dynamicType.isAccessibilitySize ? 3 : 6
        if maximumLines != nextMaximumLines { maximumLines = nextMaximumLines; geometryChanged = true }
        let category = Self.category(dynamicType)
        let updatedFont = UIFont.preferredFont(forTextStyle: .body,
            compatibleWith: UITraitCollection(preferredContentSizeCategory: category))
        if font != updatedFont { font = updatedFont; geometryChanged = true }
        prompt.font = updatedFont; prompt.text = placeholder
        let semantic: UISemanticContentAttribute = direction == .rightToLeft ? .forceRightToLeft : .forceLeftToRight
        if semanticContentAttribute != semantic { semanticContentAttribute = semantic; geometryChanged = true }
        let insets = UIEdgeInsets(top: 14, left: direction == .rightToLeft ? 0 : 16,
                                 bottom: 14, right: direction == .rightToLeft ? 16 : 0)
        if textContainerInset != insets { textContainerInset = insets; geometryChanged = true }
        accessibilityLabel = label
        let value = binding.wrappedValue
        // Observation can synchronously reenter before the workspace installs
        // this control's own draft write. That old value must not roll back the
        // native edit. A different context still reconciles immediately.
        let publishingCurrentDraft = publishingDraft != nil && publishingDraft == nextIdentity
        if replaced || (!publishingCurrentDraft && self.text != value && markedTextRange == nil) {
            #if DEBUG
            let clearsText = value.isEmpty && !self.text.isEmpty
            #endif
            reconciling = true
            let selected = selectedRange
            self.text = value
            geometryChanged = true
            if replaced { selectedRange = NSRange(location: value.utf16.count, length: 0) }
            else {
                let start = min(selected.location, value.utf16.count)
                selectedRange = NSRange(location: start, length: min(selected.length, value.utf16.count - start))
            }
            reconciling = false
            #if DEBUG
            if clearsText { inputTrace?.mark("cleared") }
            #endif
        }
        prompt.isHidden = !self.text.isEmpty
        if geometryChanged || markedTextRange != nil { invalidateIntrinsicContentSize() }
    }

    func fittingSize(width: CGFloat) -> CGSize {
        let insets = textContainerInset.top + textContainerInset.bottom
        let line = font?.lineHeight ?? UIFont.preferredFont(forTextStyle: .body).lineHeight
        let natural = sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height
        return CGSize(width: width, height: ceil(min(insets + line * CGFloat(maximumLines), max(insets + line, natural))))
    }
    override func layoutSubviews() {
        super.layoutSubviews()
        prompt.frame = CGRect(x: textContainerInset.left, y: textContainerInset.top,
            width: max(0, bounds.width - textContainerInset.left - textContainerInset.right),
            height: font?.lineHeight ?? 0)
    }
    func textViewDidChange(_ textView: UITextView) {
        #if DEBUG
        inputTrace?.mark("edit")
        #endif
        publishDraft(measureHeightChange: true)
    }
    private func publishDraft(measureHeightChange: Bool = false) {
        guard !reconciling, eligible, identity != nil, canEdit() else { return }
        let previousPublication = publishingDraft
        publishingDraft = identity
        boundText.wrappedValue = text ?? ""
        publishingDraft = previousPublication
        prompt.isHidden = !self.text.isEmpty
        if !measureHeightChange || markedTextRange != nil ||
            !bounds.width.isFinite || !bounds.height.isFinite || bounds.width <= 0 || bounds.height <= 0 ||
            fittingSize(width: bounds.width).height != bounds.height {
            invalidateIntrinsicContentSize()
        }
    }
    func textViewDidBeginEditing(_ textView: UITextView) {
        #if DEBUG
        inputTrace?.begin()
        #endif
        guard eligible, canEdit() else { cancelEditing(commit: false); return }
    }
    #if DEBUG
    func textViewDidEndEditing(_ textView: UITextView) { inputTrace?.finish() }
    func markSend() { inputTrace?.mark("send") }
    #endif
    func commitComposition() {
        guard !reconciling, eligible, canEdit() else { return }
        unmarkText()
        publishDraft()
    }
    func cancelEditing(commit: Bool = true) {
        if commit { commitComposition() }
        if isFirstResponder { resignFirstResponder() }
    }
    func retire() {
        #if DEBUG
        inputTrace?.finish()
        #endif
        reconciling = true; cancelEditing(commit: false); unmarkText(); undoManager?.removeAllActions()
        boundText = .constant(""); identity = nil; canEdit = { false }
        if editingHandle?.editor === self { editingHandle?.editor = nil }
    }
    private static func category(_ size: DynamicTypeSize) -> UIContentSizeCategory {
        switch size {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
