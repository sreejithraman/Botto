import SwiftUI
import BottoCore

struct SettingsView: View {
    @Bindable var store: AppStore
    var onConnection: () -> Void
    var onLeaveDemo: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @AppStorage("botto.appearance") private var appearance = "system"
    @Bindable private var haptics = BottoHaptics.shared
    @State private var confirmsForget = false
    @State private var isForgetting = false
    @State private var showsLicenses = false
    var body: some View {
        NavigationStack {
            Form {
                if store.isDemo {
                    Section {
                        Label("Demo workspace", systemImage: "sparkles")
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("Demo workspace. Sample spaces only.")
                            .listRowBackground(Color.clear)
                    }
                } else {
                    Section("Your connection") {
                        LabeledContent("Server", value: store.serverName)
                        LabeledContent("Status", value: store.isConnected ? "Connected" : store.link == .connecting ? "Connecting…" : "Offline")
                        if let version = store.serverInfo?.version, !version.isEmpty {
                            LabeledContent("T3 Code", value: version)
                        }
                        Button("Reconnect", systemImage: "arrow.clockwise") {
                            if let configuration = store.configuration { Task { await store.connect(configuration) } }
                        }.disabled(store.link == .connecting)
                        Button("Connection details", systemImage: "network") { onConnection() }
                    }
                }
                if let error = store.connectionError, !store.isConnected {
                    Section { Text(error).font(.subheadline).foregroundStyle(BottoTheme.error) }
                }
                Section("Appearance") {
                    Picker("Appearance", selection: $appearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                }
                Section {
                    Picker("Haptics", selection: $haptics.mode) {
                        ForEach(HapticMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    .accessibilityIdentifier("settings.haptics")
                    Toggle("Pulse while streaming", isOn: $haptics.streamingEnabled)
                        .disabled(haptics.mode == .off)
                        .accessibilityIdentifier("settings.streamingHaptics")
                } header: {
                    Text("Touch")
                } footer: {
                    Text("Subtle keeps feedback quiet. Playful adds a gentle knock and small celebrations. Streaming pulses are optional.")
                }
                if !store.isDemo {
                    Section {
                        NavigationLink {
                            T3PushSettingsView(store: store)
                        } label: {
                            Label("Notifications", systemImage: "bell.badge")
                        }
                        .accessibilityIdentifier("settings.notifications")
                        if store.t3Push.hasOtherPairings(than: store.t3PushScope) {
                            Button("Turn Off Notifications from Other Macs", role: .destructive) {
                                let current = store.t3PushScope
                                Task {
                                    await store.t3Push.disablePairings { $0 != current }
                                    store.notice = store.t3Push.notice
                                }
                            }
                            .disabled(store.t3Push.isBusy)
                        }
                    }
                }
                #if DEBUG || BOTTO_INTERNAL_TOOLS
                Section("Developer") {
                    NavigationLink {
                        DeveloperMenuView()
                    } label: {
                        Label("Developer menu", systemImage: "hammer")
                    }
                    .accessibilityIdentifier("settings.developerMenu")
                }
                #endif
                if !store.isDemo {
                    Section {
                        Button("Try demo", systemImage: "play.rectangle") {
                            Task {
                                await store.enterDemo()
                                dismiss()
                            }
                        }
                    } footer: {
                        Text("Explore sample spaces. Your saved connection and chats stay on this device.")
                    }
                }
                Section("About Botto") {
                    BottoGreeting(style: .settings)
                        .padding(.vertical, 12)
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    Button("Open-source licenses") { showsLicenses = true }
                        .listRowBackground(Color.clear)
                }
                Section {
                    if store.isDemo {
                        Button("Leave demo") {
                            dismiss()
                            if let onLeaveDemo { onLeaveDemo() }
                            else {
                                store.leaveDemo()
                                if let configuration = store.configuration { Task { await store.connect(configuration) } }
                            }
                        }
                    } else {
                        Button("Forget this connection", role: .destructive) { confirmsForget = true }
                            .disabled(isForgetting)
                    }
                } footer: {
                    if store.isDemo {
                        Text(onLeaveDemo == nil ? "Return to your own workspace." : "Return to the playground.")
                    } else {
                        Text("Removes saved pairing details, drafts, cached spaces, and notification pairings from this device. Botto’s memory and spaces stay on the Mac.")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if let notice = store.notice {
                    InlineNotice(message: notice) { store.notice = nil }
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(BottoTheme.paper)
                }
            }
            .scrollContentBackground(.hidden).background(BottoTheme.paper, ignoresSafeAreaEdges: [])
            .bottoNavigationChrome()
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $showsLicenses) { OpenSourceLicensesView(isDemo: store.isDemo) }
            .confirmationDialog("Forget this connection?", isPresented: $confirmsForget, titleVisibility: .visible) {
                Button("Forget on this device", role: .destructive) {
                    isForgetting = true
                    Task {
                        await store.forgetConnectionWithPush()
                        isForgetting = false
                        if store.configuration == nil { dismiss() }
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Saved pairing details, drafts, cached messages, and notifications will be removed from this device. Botto’s memory and spaces stay on the Mac.")
            }
        }.tint(BottoTheme.action)
    }
}

private struct OpenSourceLicensesView: View {
    let isDemo: Bool
    @Environment(\.dismiss) private var dismiss
    private var hermex: String { resource("Hermex", fileExtension: "txt", subdirectory: "LICENSES") }
    private var notices: String { resource("THIRD_PARTY_NOTICES", fileExtension: "md") }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if isDemo { DemoBanner() }
                    Text("Botto · MIT License").font(.title2.weight(.bold))
                    Text(resource("LICENSE")).font(.subheadline).textSelection(.enabled)
                    Divider()
                    Text("Third-party notices").font(.title2.weight(.bold))
                    Text(notices).font(.subheadline).textSelection(.enabled)
                    Divider()
                    Text("Hermex · MIT License").font(.title2.weight(.bold))
                    Text(hermex).font(.subheadline).textSelection(.enabled)
                    Divider()
                    Text("Bloub · MIT License").font(.title2.weight(.bold))
                    Text(resource("Bloub", fileExtension: "txt", subdirectory: "LICENSES")).font(.subheadline).textSelection(.enabled)
                    Divider()
                    Text("Blobatar · MIT License").font(.title2.weight(.bold))
                    Text(resource("Blobatar", fileExtension: "txt", subdirectory: "LICENSES")).font(.subheadline).textSelection(.enabled)
                    Divider()
                    Text("Diagram rendering").font(.title2.weight(.bold))
                    NavigationLink("Pele · MIT and ISC licenses") {
                        ScrollView {
                            Text(resource("Pele", fileExtension: "txt", subdirectory: "LICENSES"))
                                .font(.subheadline).textSelection(.enabled).padding()
                        }
                        .bottoNavigationChrome()
                        .navigationTitle("Pele").navigationBarTitleDisplayMode(.inline)
                    }
                }
                .frame(maxWidth: 680, alignment: .leading).padding(24).frame(maxWidth: .infinity)
            }
            .background(BottoTheme.paper, ignoresSafeAreaEdges: [])
            .bottoNavigationChrome()
            .navigationTitle("Open-source licenses").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
    private func resource(_ name: String, fileExtension ext: String? = nil, subdirectory: String? = nil) -> String {
        guard let url = Bundle.main.url(forResource: name, withExtension: ext)
                ?? Bundle.main.url(forResource: name, withExtension: ext, subdirectory: subdirectory),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This notice couldn’t be loaded from the app bundle."
        }
        return text
    }
}
