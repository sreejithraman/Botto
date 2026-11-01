import SwiftUI
import BottoCore

/// The same shared shapes and palette for creation and explicit profile edits.
struct BotAvatarPicker: View {
    let profileID: String
    let current: BotAppearance
    @Binding var selection: BotAvatarChoice?
    var hasImage = false
    @State private var retainedCustomChoice: BotAvatarChoice?
    @State private var hasRetainedCustomChoice = false
    private enum Mode: String { case automatic = "Match the name", custom = "Custom" }
    @Environment(\.dynamicTypeSize) private var typeSize

    private var appearance: BotAppearance { selection?.applying(to: current) ?? current }
    private var edit: BotAvatarEdit {
        switch selection {
        case .edit(let edit): return edit
        case nil: return BotAvatarEdit()
        default: return BotAvatarEdit(shape: face.shape, color: colorOverride.map { .value($0) } ?? .automatic)
        }
    }
    private var face: BotFace { appearance.face(for: profileID) }
    private var colorOverride: String? { appearance.color.flatMap { $0.isEmpty ? nil : $0 } }
    private var columns: [GridItem] { [GridItem(.adaptive(minimum: typeSize.isAccessibilitySize ? 140 : 76), spacing: 12)] }
    private var canChooseColor: Bool { BotAvatarShape.pickerCases.contains(face.shape) }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Picker("Avatar", selection: Binding(get: { mode }, set: chooseMode)) {
                Text(Mode.automatic.rawValue).tag(Mode.automatic)
                Text(Mode.custom.rawValue).tag(Mode.custom)
            }
            .pickerStyle(.menu)
            .accessibilityIdentifier("avatar-mode")
            if mode == .custom {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Shape").font(.subheadline.weight(.semibold))
                    if appearance.rawShape != nil, appearance.shape == nil, !appearance.isGenerated {
                        Text("This shape uses a local preview. Changing its color keeps the saved shape.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(BotAvatarShape.pickerCases) { shape in
                            let selected = appearance.shape == shape || (appearance.rawShape == nil && face.shape == shape)
                            Button {
                                var changed = edit; changed.shape = shape
                                selection = .edit(changed)
                                if !selected { BottoHaptics.shared.play(.avatarSelection) }
                            } label: {
                                VStack(spacing: 6) {
                                    BotAvatar(profile: BotProfile(id: profileID, name: "", appearance: BotAppearance(shape: shape, color: face.color)),
                                              size: 44, motion: .still)
                                    Text(shape.label).font(.caption).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity).padding(8)
                                .background(selected ? BottoTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .topTrailing) { if selected { selectionMark } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(shape.label) shape")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("avatar-shape-\(shape.rawValue)")
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("Color").font(.subheadline.weight(.semibold))
                    if !canChooseColor {
                        Text("Choose a shape before changing this generated avatar’s color.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if let colorOverride, !BotAvatarColors.isValid(colorOverride) {
                        Text("This color can’t be previewed here. Its saved value is kept when you change the shape.")
                            .font(.subheadline).foregroundStyle(.secondary)
                    } else if let colorOverride, BotAvatarColor.matching(colorOverride) == nil {
                        Label("Custom color · kept when you change the shape", systemImage: "paintpalette")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    LazyVGrid(columns: columns, spacing: 12) {
                        Button {
                            let changed = colorOverride != nil
                            chooseColor(.automatic)
                            if changed { BottoHaptics.shared.play(.selection) }
                        } label: {
                            VStack(spacing: 6) {
                                Circle()
                                    .fill(AngularGradient(colors: BotAvatarColor.palette.map(\.swatch), center: .center))
                                    .overlay {
                                        Circle().fill(BottoTheme.paper).padding(4)
                                        Text("A").font(.caption.weight(.semibold)).foregroundStyle(BottoTheme.ink)
                                    }
                                    .frame(width: 30, height: 30)
                                Text("Auto").font(.caption).multilineTextAlignment(.center)
                            }
                            .frame(maxWidth: .infinity).padding(8)
                            .background(colorOverride == nil ? BottoTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(alignment: .topTrailing) { if colorOverride == nil { selectionMark } }
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Automatic color")
                        .accessibilityAddTraits(colorOverride == nil ? .isSelected : [])
                        .accessibilityIdentifier("avatar-color-auto")
                        ForEach(BotAvatarColor.palette) { color in
                            let selected = colorOverride.flatMap(BotAvatarColor.matching)?.id == color.id
                            Button {
                                chooseColor(.value(color.value))
                                if !selected { BottoHaptics.shared.play(.selection) }
                            } label: {
                                VStack(spacing: 6) {
                                    Circle().fill(color.swatch).frame(width: 30, height: 30)
                                    Text(color.localizedName).font(.caption).multilineTextAlignment(.center)
                                }
                                .frame(maxWidth: .infinity).padding(8)
                                .background(selected ? BottoTheme.selection : .clear, in: RoundedRectangle(cornerRadius: 14))
                                .overlay(alignment: .topTrailing) { if selected { selectionMark } }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(color.localizedName) color")
                            .accessibilityAddTraits(selected ? .isSelected : [])
                            .accessibilityIdentifier("avatar-color-\(color.id)")
                        }
                    }
                    .disabled(!canChooseColor)
                }
            }
        }
    }

    private var mode: Mode {
        if selection == .automatic { return .automatic }
        if selection != nil { return .custom }
        return hasImage || current.custom || current.rawShape != nil || colorOverride != nil ? .custom : .automatic
    }

    private func chooseMode(_ next: Mode) {
        guard next != mode else { return }
        switch next {
        case .automatic:
            retainedCustomChoice = selection
            hasRetainedCustomChoice = true
            selection = .automatic
        case .custom:
            selection = hasRetainedCustomChoice ? retainedCustomChoice : .face(face)
        }
    }

    private func chooseColor(_ color: BotAvatarEdit.Color) {
        var changed = edit
        // Color edits deliberately leave Blobatar mode, as explained by the editor.
        if appearance.isGenerated { changed.shape = face.shape }
        changed.color = color
        selection = .edit(changed)
    }

    private var selectionMark: some View {
        Image(systemName: "checkmark.circle.fill").foregroundStyle(BottoTheme.onSelection)
            .background(BottoTheme.paper, in: Circle()).accessibilityHidden(true)
    }
}
