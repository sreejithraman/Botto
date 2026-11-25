import SwiftUI
import BottoCore

/// The connection sheet: pairing with a Mac, or a Hermes server's sign-in for those who use one.
struct ConnectionView: View {
    @Bindable var store: AppStore
    @State private var backend: ConnectionBackend
    @State private var input: String
    /// Each link that arrives starts its page over.
    @State private var inputRevision = 0

    init(store: AppStore, input: String = "") {
        self.store = store
        _input = State(initialValue: input)
        _backend = State(initialValue: .initial(input: input, saved: store.configuration, isDemo: store.isDemo))
    }

    var body: some View {
        NavigationStack {
            switch backend {
            case .t3:
                T3PairingView(store: store, input: input, onUseHermes: { open(.hermes, input: $0) }).id(inputRevision)
            case .hermes:
                HermesConnectionForm(store: store, input: input, onPairMac: { open(.t3, input: $0) }).id(inputRevision)
            }
        }
        .onChange(of: store.pendingConnectionInput) { _, pending in
            guard let pending else { return }
            open(ConnectionBackend.named(by: pending) ?? backend, input: pending)
            store.pendingConnectionInput = nil
        }
        .onAppear { store.pendingConnectionInput = nil }
        .tint(BottoTheme.action)
    }

    private func open(_ backend: ConnectionBackend, input: String = "") {
        self.backend = backend
        self.input = input
        inputRevision += 1
    }
}

private struct HermesConnectionForm: View {
    let store: AppStore
    let onPairMac: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var address: String
    @State private var reviewedURL: URL?
    @State private var username = ""
    @State private var password = ""
    @State private var clientID = ""
    @State private var clientSecret = ""
    @State private var allowHTTP = false
    @State private var showsScanner = false
    @State private var error: String?
    @State private var isSubmitting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var attemptID = UUID()

    init(store: AppStore, input: String = "", onPairMac: @escaping (String) -> Void) {
        self.store = store
        self.onPairMac = onPairMac
        let saved = store.isT3Workspace ? "" : store.configuration?.serverURL.absoluteString ?? ""
        _address = State(initialValue: input.isEmpty ? saved : input)
    }

    var body: some View {
        Form {
            if let destination = reviewedURL {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(destination.scheme == "https" ? "Secure connection" : "Trusted HTTP connection",
                              systemImage: destination.scheme == "https" ? "lock" : "network")
                            .font(.subheadline).foregroundStyle(.secondary)
                        Text(destination.absoluteString).font(.headline).textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 6)
                    Button("Change address") { clearReview() }
                        .disabled(isSubmitting)
                } header: {
                    Text("Reviewed server")
                } footer: {
                    Text("Only continue if you recognize this server. Your sign-in will be sent to this address.")
                }
                hermesCredentials
                if let error { errorSection(error) }
                Section {
                    Button {
                        connect(destination, inBrowser: false)
                    } label: {
                        primaryLabel(isSubmitting ? "Connecting…" : "Connect")
                    }
                    .buttonStyle(BottoPrimaryButtonStyle())
                    .disabled(isSubmitting)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                    Button {
                        connect(destination, inBrowser: true)
                    } label: {
                        Text("Continue in browser")
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.plain).foregroundStyle(BottoTheme.action)
                    .disabled(isSubmitting)
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                if isSubmitting {
                    Section {
                        let host = destination.host ?? "your server"
                        Text("Signing in to \(host)…")
                            .foregroundStyle(.secondary)
                    }
                }
            } else {
                Section {
                    TextField("https://hermes.example.com", text: $address, axis: .vertical)
                        .keyboardType(.URL).textContentType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityLabel("Hermes server address or connection code")
                    HStack {
                        PasteButton(payloadType: String.self) { values in
                            if let value = values.first { receiveInput(value) }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        Spacer(minLength: 16)
                        Button { showsScanner = true } label: {
                            Label("Scan QR", systemImage: "qrcode.viewfinder")
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(minHeight: 44)
                        }
                        .accessibilityLabel("Scan connection QR")
                    }
                    .buttonStyle(.borderless)
                } header: {
                    Text("Server address or connection code")
                } footer: {
                    Text("You’ll review the address before signing in.")
                }
                if let error { errorSection(error) }
                Section {
                    Button { reviewAddress() } label: {
                        primaryLabel("Review destination")
                    }
                    .buttonStyle(BottoPrimaryButtonStyle())
                    .disabled(address.isEmpty)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                }
                HermesSetupSection()
                Section {
                    DisclosureGroup("Trusted local network") {
                        Toggle("Allow an HTTP connection", isOn: $allowHTTP)
                        Text("HTTP sends sign-in details and messages without encryption. Enable only for a server on a network you trust.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    .listRowBackground(Color.clear)
                }
            }
            Section {
                Button("Pair with your Mac instead") { onPairMac("") }
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .foregroundStyle(BottoTheme.action)
                    .disabled(isSubmitting)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden).background(BottoTheme.paper, ignoresSafeAreaEdges: [])
        .bottoNavigationChrome()
        .navigationTitle("Connect Hermes").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancelAttempt(); dismiss() }
            }
        }
        .sheet(isPresented: $showsScanner) {
            PairingScannerView { scanned in
                receiveInput(scanned)
                showsScanner = false
                reviewAddress()
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onDisappear { cancelAttempt() }
        .onChange(of: address) { _, value in
            if T3PairingReview.isPairingLink(value) { onPairMac(value) }
        }
    }

    @ViewBuilder private var hermesCredentials: some View {
        Section {
            TextField("Username", text: $username)
                .textContentType(.username).textInputAutocapitalization(.never).autocorrectionDisabled()
            SecureField("Password", text: $password).textContentType(.password).privacySensitive()
        } header: {
            Text("Sign in to Hermes")
        } footer: {
            Text("Use your Hermes server account.")
        }
        Section {
            DisclosureGroup("Advanced connection") {
                TextField("Cloudflare Access client ID", text: $clientID)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("Cloudflare Access client secret", text: $clientSecret).privacySensitive()
                Text("Only needed when your server uses a Cloudflare Access service token.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
    private func primaryLabel(_ title: String) -> some View {
        Text(title)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 32).padding(.vertical, 16)
    }
    private func errorSection(_ text: String) -> some View {
        Section {
            Label(text, systemImage: "exclamationmark.circle")
                .foregroundStyle(BottoTheme.error).font(.subheadline)
        }
    }
    private func reviewAddress() {
        do {
            reviewedURL = try PairingAddress.parse(address, allowInsecureHTTP: allowHTTP)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func clearReview() {
        reviewedURL = nil
        error = nil
    }

    private func receiveInput(_ input: String) {
        clearReview()
        address = input
    }
    private var headers: [String: String] {
        var result: [String: String] = [:]
        if !clientID.isEmpty { result["CF-Access-Client-Id"] = clientID }
        if !clientSecret.isEmpty { result["CF-Access-Client-Secret"] = clientSecret }
        return result
    }
    private func connect(_ destination: URL, inBrowser: Bool) {
        guard !isSubmitting else { return }
        isSubmitting = true; error = nil
        let owner = UUID()
        attemptID = owner
        let submittedHeaders = headers
        let submittedUsername = username
        let submittedPassword = password
        connectionTask = Task { @MainActor in
            defer {
                if attemptID == owner { isSubmitting = false; connectionTask = nil }
            }
            do {
                let candidate: ConnectionConfiguration
                if inBrowser {
                    candidate = try await BrowserSignIn.authenticate(serverURL: destination, connectionHeaders: submittedHeaders)
                } else {
                    candidate = ConnectionConfiguration(serverURL: destination, username: submittedUsername, password: submittedPassword, connectionHeaders: submittedHeaders)
                }
                try Task.checkCancellation()
                guard attemptID == owner else { return }
                if store.isDemo { store.leaveDemo() }
                var failure: (any Error)?
                let connected = await store.connect(candidate, onConnected: {
                    guard attemptID == owner, !Task.isCancelled, scenePhase == .active else { return }
                    BottoHaptics.shared.play(.celebration)
                }, onFailure: { failure = $0 })
                guard !Task.isCancelled, attemptID == owner else { return }
                if connected { dismiss() }
                else {
                    error = store.connectionError ?? "Couldn’t connect. Check your server and try again."
                    if let failure, scenePhase == .active { BottoHaptics.shared.play(.failure(failure)) }
                }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, attemptID == owner else { return }
                self.error = error.localizedDescription
                if scenePhase == .active { BottoHaptics.shared.play(.failure(error)) }
            }
        }
    }
    private func cancelAttempt() {
        attemptID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        isSubmitting = false
    }
}
