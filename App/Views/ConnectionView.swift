import SwiftUI
import BottoCore

struct ConnectionView: View {
    private enum Backend: Hashable { case hermes, t3 }

    @Bindable var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var address: String
    @State private var backend: Backend
    @State private var reviewedURL: URL?
    @State private var reviewedCredential: String?
    @State private var pairedConfiguration: ConnectionConfiguration?
    @State private var pairingCode = ""
    @State private var setupRevision = 0
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

    init(store: AppStore, input: String = "") {
        self.store = store
        _address = State(initialValue: input.isEmpty ? store.configuration?.serverURL.absoluteString ?? "" : input)
        _backend = State(initialValue: Self.backend(for: input, fallback: store.isT3Workspace ? .t3 : .hermes))
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { scroll in
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
                            Text(backend == .t3
                                 ? "Only continue if you recognize this server. Your pairing code will be sent to this address."
                                 : "Only continue if you recognize this server. Your sign-in will be sent to this address.")
                        }
                        if backend == .hermes { hermesCredentials }
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
                            if backend == .hermes {
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
                        }
                        if isSubmitting {
                            Section {
                                let host = destination.host ?? "your server"
                                Text(backend == .t3 ? "Pairing with \(host)…" : "Signing in to \(host)…")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Section {
                            Picker("Backend", selection: Binding(get: { backend }, set: {
                                backend = $0
                                clearReview()
                            })) {
                                Text("Hermes").tag(Backend.hermes)
                                Text("T3 Code").tag(Backend.t3)
                            }.pickerStyle(.segmented)
                        }
                        Section {
                            TextField(backend == .t3 ? "T3 pairing link or server URL" : "https://hermes.example.com",
                                      text: $address, axis: .vertical)
                                .keyboardType(.URL).textContentType(.URL)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .privacySensitive(backend == .t3)
                                .accessibilityLabel(backend == .t3 ? "T3 pairing link or server URL" : "Hermes server address or connection code")
                            if backend == .t3, !Self.isT3Link(address) {
                                SecureField("Pairing code", text: $pairingCode)
                                    .textInputAutocapitalization(.never).autocorrectionDisabled().privacySensitive()
                            }
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
                            Text(backend == .t3 ? "You’ll review the address before pairing." : "You’ll review the address before signing in.")
                        }
                        .id("connection-address")
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
                        if backend == .hermes { HermesSetupSection().id(setupRevision) }
                        Section {
                            DisclosureGroup("Trusted local network") {
                                Toggle("Allow an HTTP connection", isOn: $allowHTTP)
                                    Text(backend == .t3
                                         ? "HTTP sends pairing details and messages without encryption. Enable only for a trusted LAN or Tailscale address."
                                         : "HTTP sends sign-in details and messages without encryption. Enable only for a server on a network you trust.")
                                    .font(.footnote).foregroundStyle(.secondary)
                            }
                            .listRowBackground(Color.clear)
                        }
                    }
                    if backend == .t3 {
                        Section {} footer: {
                            Text("Direct pairing over LAN, Tailscale, or your own tunnel. No T3 account required.")
                        }
                    }
                }
                .onChange(of: setupRevision) { _, _ in scroll.scrollTo("connection-address", anchor: .top) }
                .scrollDismissesKeyboard(.interactively)
                .scrollContentBackground(.hidden).background(BottoTheme.paper, ignoresSafeAreaEdges: [])
                .bottoNavigationChrome()
                .navigationTitle(backend == .t3 ? "Connect T3 Code" : "Connect Hermes").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { cancelAttempt(); dismiss() }
                    }
                }
                .sheet(isPresented: $showsScanner) {
                    PairingScannerView(isT3: backend == .t3) { scanned in
                        receiveInput(scanned)
                        showsScanner = false
                        reviewAddress()
                    }
                }
            }
        }
        .interactiveDismissDisabled(isSubmitting)
        .onChange(of: store.pendingConnectionInput) { _, input in
            guard let input else { return }
            cancelAttempt()
            showsScanner = false
            setupRevision += 1
            receiveInput(input)
            store.pendingConnectionInput = nil
        }
        .onAppear { store.pendingConnectionInput = nil }
        .onDisappear { cancelAttempt() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, backend == .t3 { cancelAttempt() }
        }
        .onChange(of: address) { _, value in
            backend = Self.backend(for: value, fallback: backend)
        }
        .tint(BottoTheme.action)
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
            if backend == .t3 {
                let input = try T3PairingExchange.parse(address, credential: Self.isT3Link(address) ? nil : pairingCode)
                reviewedURL = try PairingAddress.parse(input.origin.absoluteString, allowInsecureHTTP: allowHTTP)
                reviewedCredential = input.credential
            } else {
                reviewedURL = try PairingAddress.parse(address, allowInsecureHTTP: allowHTTP)
            }
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private static func isT3Link(_ input: String) -> Bool {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        return URLComponents(string: text)?.scheme?.lowercased() == "t3code" || (try? T3PairingExchange.parse(text)) != nil
    }

    private static func backend(for input: String, fallback: Backend) -> Backend {
        if isT3Link(input) { return .t3 }
        let scheme = URLComponents(string: input.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        if let scheme, ["hermes", "botto"].contains(scheme) { return .hermes }
        return fallback
    }

    private func clearReview() {
        reviewedURL = nil
        reviewedCredential = nil
        pairedConfiguration = nil
        error = nil
    }

    private func receiveInput(_ input: String) {
        clearReview()
        backend = Self.backend(for: input, fallback: backend)
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
        let credential = reviewedCredential
        let submittedBackend = backend
        let existingPairing = pairedConfiguration
        connectionTask = Task { @MainActor in
            defer {
                if attemptID == owner { isSubmitting = false; connectionTask = nil }
            }
            do {
                let candidate: ConnectionConfiguration
                if submittedBackend == .t3 {
                    guard let credential else { throw T3PairingError.missingCredential }
                    if let existingPairing { candidate = existingPairing }
                    else {
                        candidate = try await T3PairingExchange().exchangePairingCredential(
                            origin: destination, credential: credential, clientLabel: "Botto"
                        ).configuration
                        try Task.checkCancellation()
                        guard attemptID == owner else { return }
                        pairedConfiguration = candidate
                    }
                } else if inBrowser {
                    candidate = try await BrowserSignIn.authenticate(serverURL: destination, connectionHeaders: submittedHeaders)
                } else {
                    candidate = ConnectionConfiguration(serverURL: destination, username: submittedUsername, password: submittedPassword, connectionHeaders: submittedHeaders)
                }
                try Task.checkCancellation()
                guard attemptID == owner, submittedBackend != .t3 || scenePhase == .active else { return }
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
