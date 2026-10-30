import SwiftUI
import BottoCore

struct PushSettingsView: View {
    @Bindable var coordinator: PushCoordinator
    var testDestination: PushDestination?
    @State private var confirmsInstall = false
    @State private var confirmsDisable = false
    @State private var removingDevice: PushDevice?
    @Environment(\.openURL) private var openURL

    private var pluginSource: String? { Bundle.main.object(forInfoDictionaryKey: "BottoPushPluginSource") as? String }
    private var pluginRef: String? { Bundle.main.object(forInfoDictionaryKey: "BottoPushPluginRef") as? String }
    private var devices: [PushDevice] {
        coordinator.status?.devices.filter {
            $0.state != .removed || $0.pendingRemoval == true || coordinator.isCurrentDevice($0)
        } ?? []
    }
    private var canInstall: Bool {
        guard let pluginSource, let source = URL(string: pluginSource), source.scheme == "https",
              let pluginRef else { return false }
        return PushEnvelope.validHex(pluginRef, count: 40)
    }

    var body: some View {
        Form {
            if coordinator.profiles.count > 1 {
                Section("Bot") {
                    Picker("Notifications for", selection: Binding(get: { coordinator.selectedProfileID ?? "" }, set: { id in
                        Task { await coordinator.selectProfile(id) }
                    })) {
                        ForEach(coordinator.profiles) { bot in Text(bot.name).tag(bot.id) }
                    }
                    .disabled(coordinator.isBusy)
                }
            }
            Section {
                Text(coordinator.stateDescription)
                if coordinator.storageUnavailable {
                    Button("Retry secure storage") { coordinator.retryStorage() }
                } else if coordinator.hasPairing {
                    Button("Retry notification setup") { Task { await coordinator.resume() } }
                        .disabled(coordinator.isBusy)
                    Button("Turn off for this device", role: .destructive) { confirmsDisable = true }
                        .disabled(coordinator.isBusy)
                } else {
                    Button("Enable notifications") { Task { await coordinator.enable() } }
                        .disabled(!coordinator.canEnable)
                }
                Button { Task { await coordinator.refresh() } } label: {
                    HStack { Text("Check host support"); if coordinator.isChecking { ProgressView() } }
                }
                .disabled(coordinator.isBusy || coordinator.isDemo || coordinator.isChecking)
                Button("Open iOS notification settings") {
                    if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
                }
            } header: { Text("Notifications") }
              footer: { Text("Botto encrypts previews on your Hermes host and decrypts them on this device. Your iPhone or iPad controls lock-screen visibility.") }

            if coordinator.hasPairing {
                Section("Notify me about") {
                    preference("Finished replies", \.replies)
                    preference("Approvals and questions", \.requests)
                    preference("Turn failures", \.failures)
                    preference("Show encrypted previews", \.previews)
                }
                if let testDestination, testDestination.profileID == coordinator.selectedProfileID {
                    Section {
                        Button("Send test notification") { Task { await coordinator.sendTest(destination: testDestination) } }
                            .disabled(coordinator.isBusy || !coordinator.isEnabled)
                    }
                }
            }
            if !coordinator.isEnabled {
                Section("Hermes plugin") {
                    Text("Install and enable the Botto push plugin for each Hermes profile that should send notifications. The host must support Botto's native notification event contract.")
                    if canInstall {
                        Button("Install plugin on this host") { confirmsInstall = true }.disabled(coordinator.isBusy || coordinator.isDemo)
                    } else {
                        Text("This build does not include a published, pinned plugin installer. Follow the Botto push deployment guide on your host, then check support again.")
                        Text("hermes --profile PROFILE plugins install PLUGIN_SOURCE --ref PINNED_COMMIT --enable --yes-deps")
                            .font(.footnote.monospaced()).textSelection(.enabled)
                    }
                    if coordinator.restartRequired { Text("The host reports that a restart is required. Restart it deliberately when its running work can be interrupted.") }
                }
            }
            if !devices.isEmpty {
                Section("Paired devices") {
                    ForEach(devices) { device in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(coordinator.isCurrentDevice(device) ? "This device" : device.deviceName ?? "Other device")
                            Text(String(device.deviceID.prefix(8))).font(.caption.monospaced()).foregroundStyle(.secondary)
                            if device.pendingRemoval == true { Text("Remote removal pending").font(.caption) }
                            else if device.state == .relayRetired { Text("Notifications need attention").font(.caption) }
                            if device.pendingRemoval != true, device.state != .removed,
                               device.active != false || device.state == .relayRetired {
                                Button("Remove device", role: .destructive) { removingDevice = device }.disabled(coordinator.isBusy)
                            }
                        }
                    }
                }
            }
            if coordinator.pendingRemovalCount > 0 {
                Section("Removal pending") {
                    Text("Some devices were removed locally, but remote removal is not confirmed. Reconnect to the original Hermes host to retry.")
                    Button("Retry remote removal") { Task { await coordinator.retryRemovals() } }
                        .disabled(coordinator.isBusy || coordinator.isDemo)
                }
            }
            if let notice = coordinator.notice {
                Section { Text(notice).accessibilityIdentifier("push-notice") }
            }
        }
        .scrollContentBackground(.hidden).background(BottoTheme.paper)
        .bottoNavigationChrome()
        .navigationTitle("Notifications").navigationBarTitleDisplayMode(.inline)
        .task { await coordinator.refresh() }
        .confirmationDialog("Install the Botto notification plugin?", isPresented: $confirmsInstall, titleVisibility: .visible) {
            Button("Install and enable") {
                if let pluginSource, let pluginRef { Task { await coordinator.installPlugin(identifier: pluginSource, ref: pluginRef) } }
            }
        } message: { Text("This changes the selected Hermes profile on your host. Botto will report any required restart without interrupting running work automatically.") }
        .confirmationDialog("Turn off notifications on this device?", isPresented: $confirmsDisable, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { Task { await coordinator.disable() } }
        } message: { Text("The local preview key will be removed and remote delivery revoked. Other devices keep their own pairing.") }
        .confirmationDialog("Remove this notification pairing?", isPresented: Binding(get: { removingDevice != nil }, set: { if !$0 { removingDevice = nil } }), titleVisibility: .visible) {
            if let device = removingDevice { Button("Remove device", role: .destructive) { Task { await coordinator.removeDevice(device) } } }
        } message: { Text("Future alerts for this pairing stop. This does not erase old alerts or revoke the device's Hermes sign-in credentials.") }
    }

    private func preference(_ title: String, _ keyPath: WritableKeyPath<PushPreferences, Bool>) -> some View {
        Toggle(title, isOn: Binding(get: { coordinator.preferences[keyPath: keyPath] }, set: { enabled in
            var next = coordinator.preferences; next[keyPath: keyPath] = enabled
            Task { await coordinator.updatePreferences(next) }
        })).disabled(coordinator.isBusy)
    }
}
