import SwiftUI
import BottoCore

/// Pairs this phone with Botto on a Mac: scan or paste its link, look over the address, then connect.
/// Nothing is sent until the address has been reviewed.
struct T3PairingView: View {
    let store: AppStore
    let exchange: T3PairingExchange
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var input: String
    @State private var code = ""
    @State private var review: T3PairingReview?
    @State private var allowsHTTP = false
    /// A one-time code that was already redeemed, so a retry after a failed connection doesn't spend it twice.
    @State private var paired: ConnectionConfiguration?
    @State private var showsScanner = false
    @State private var typesAddress: Bool
    @State private var error: String?
    @State private var isConnecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var attemptID = UUID()

    init(store: AppStore, input: String = "", exchange: T3PairingExchange = T3PairingExchange()) {
        self.store = store
        self.exchange = exchange
        let saved = store.configuration?.serverURL.absoluteString ?? ""
        _input = State(initialValue: input.isEmpty ? saved : input)
        _typesAddress = State(initialValue: !input.isEmpty)
    }

    var body: some View {
        ScrollView {
            Group {
                if let review { reviewPage(review) } else { linkPage }
            }
            .frame(maxWidth: 480)
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 32)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollDismissesKeyboard(.interactively)
        .background(BottoTheme.paper, ignoresSafeAreaEdges: .all)
        .bottoNavigationChrome()
        .navigationTitle("Pair with your Mac").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { cancelAttempt(); dismiss() }
            }
        }
        .sheet(isPresented: $showsScanner) {
            PairingScannerView { scanned in
                showsScanner = false
                receive(scanned)
            }
        }
        .interactiveDismissDisabled(isConnecting)
        .onAppear {
            // A link handed over from elsewhere still stops at the address review.
            if review == nil, error == nil, T3PairingReview.isPairingLink(input) { reviewInput() }
        }
        .onDisappear { cancelAttempt() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { cancelAttempt() } }
    }

    // MARK: Link

    private var linkPage: some View {
        VStack(spacing: 0) {
            BotAvatarMark(profile: BottoBrand.squircle.profile, size: 96)
                .accessibilityHidden(true)
            Text("Find Botto on your Mac")
                .font(.system(.title, design: .rounded, weight: .heavy))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 18)
            Text("Open Botto there and choose Pair Phone from the Engine menu. Then scan the code it shows.")
                .font(.body).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            if let error { notice(error).padding(.top, 20) }
            Button { showsScanner = true } label: {
                label("Scan the code", systemImage: "qrcode.viewfinder")
            }
            .buttonStyle(BottoPrimaryButtonStyle())
            .accessibilityIdentifier("t3-pair-scan")
            .padding(.top, 28)
            HStack(spacing: 12) {
                Text("Have the link?").font(.subheadline).foregroundStyle(.secondary)
                PasteButton(payloadType: String.self) { values in
                    if let value = values.first { receive(value) }
                }
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .tint(BottoTheme.action)
            }
            .padding(.top, 14)
            typedAddress.padding(.top, 20)
            Text("Your phone talks straight to your Mac over Wi-Fi, Tailscale, or your own tunnel. No account needed.")
                .font(.footnote).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 24)
        }
    }

    private var typedAddress: some View {
        VStack(spacing: 12) {
            Button { withAnimation(.snappy) { typesAddress.toggle() } } label: {
                HStack(spacing: 6) {
                    Text("Type it instead")
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(typesAddress ? 90 : 0))
                }
                .font(.subheadline.weight(.medium)).foregroundStyle(BottoTheme.action)
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityValue(typesAddress ? "Expanded" : "Collapsed")
            .accessibilityIdentifier("t3-pair-type")
            if typesAddress {
                VStack(spacing: 10) {
                    field {
                        TextField("Pairing link or address", text: $input, axis: .vertical)
                            .keyboardType(.URL).textContentType(.URL)
                            .privacySensitive()
                            .accessibilityIdentifier("t3-pair-address")
                    }
                    if !T3PairingReview.isPairingLink(input) {
                        field {
                            SecureField("Pairing code", text: $code)
                                .privacySensitive()
                                .accessibilityIdentifier("t3-pair-code")
                        }
                    }
                    Button("Review address", action: reviewInput)
                        .buttonStyle(BottoPillButtonStyle())
                        .disabled(input.isEmpty)
                        .accessibilityIdentifier("t3-pair-review")
                }
            }
        }
    }

    private func field(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .textInputAutocapitalization(.never).autocorrectionDisabled()
            .padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 50)
            .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: Review

    private func reviewPage(_ review: T3PairingReview) -> some View {
        VStack(spacing: 0) {
            Image(systemName: review.isEncrypted ? "lock.fill" : "network")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(BottoTheme.action)
                .frame(width: 76, height: 76)
                .background(BottoTheme.selection, in: Circle())
                .accessibilityHidden(true)
            Text("Is this your Mac?")
                .font(.system(.title, design: .rounded, weight: .heavy))
                .multilineTextAlignment(.center)
                .accessibilityAddTraits(.isHeader)
                .padding(.top, 18)
            VStack(spacing: 14) {
                ForEach(Array(review.routes.enumerated()), id: \.element) { index, route in
                    if index > 0 { Divider() }
                    routeRow(route, isPrimary: index == 0)
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity)
            .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .padding(.top, 20)
            Text(review.routes.count > 1
                 ? "Continue only if you recognize these addresses. Your pairing code is sent to the first one that answers, secure ones first."
                 : "Continue only if you recognize this address. Your pairing code is sent there.")
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)
            if store.hasOlderSavedSetup {
                Text("Pairing removes the older setup and its saved messages from this device.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 12)
            }
            if !review.isEncrypted { httpChoice(review).padding(.top, 18) }
            if let error { notice(error).padding(.top, 18) }
            Button { connect(review) } label: {
                label(isConnecting ? "Connecting…" : "Connect", systemImage: nil)
            }
            .buttonStyle(BottoPrimaryButtonStyle())
            .disabled(isConnecting || !(review.hasSecureRoute || allowsHTTP))
            .accessibilityIdentifier("t3-pair-connect")
            .padding(.top, 24)
            Button("Change address") { clearReview() }
                .font(.subheadline.weight(.medium)).foregroundStyle(BottoTheme.action)
                .frame(minHeight: 44)
                .disabled(isConnecting)
                .padding(.top, 4)
        }
    }

    private func routeRow(_ route: URL, isPrimary: Bool) -> some View {
        VStack(spacing: 4) {
            Text(route.absoluteString)
                .font(.headline).textSelection(.enabled)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier(isPrimary ? "t3-pair-destination" : "t3-pair-route")
            Text(Self.routeDetail(route))
                .font(.subheadline).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }

    private static func routeDetail(_ route: URL) -> LocalizedStringKey {
        switch (PairingRoutes.kind(of: route), route.scheme == "https") {
        case (.tailscale, true): "Tailscale, secure connection"
        case (_, true): "Secure connection"
        case (.tailscale, false): "Tailscale, not encrypted"
        default: "Local connection, not encrypted"
        }
    }

    private func httpChoice(_ review: T3PairingReview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Allow an HTTP connection", isOn: $allowsHTTP)
                .font(.body.weight(.semibold))
                .tint(BottoTheme.action)
                // Once the code is redeemed, the consent it was sent under stays as it was.
                .disabled(isConnecting || paired != nil)
                .accessibilityIdentifier("t3-pair-allow-http")
            Text(review.hasSecureRoute
                 ? "HTTP sends pairing details and messages without encryption. Turn it on only if the LAN and Tailscale addresses above are yours. Otherwise Botto uses only the secure address."
                 : "HTTP sends pairing details and messages without encryption. Turn it on only for a trusted LAN or Tailscale address.")
                .font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .background(BottoTheme.surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func notice(_ message: String) -> some View {
        InlineNotice(message: message) { error = nil }
            .frame(maxWidth: .infinity)
    }

    private func label(_ title: LocalizedStringKey, systemImage: String?) -> some View {
        HStack(spacing: 10) {
            if let systemImage { Image(systemName: systemImage).accessibilityHidden(true) }
            Text(title).multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 24).padding(.vertical, 14)
    }

    // MARK: Actions

    private func receive(_ text: String) {
        clearReview()
        input = text
        code = ""
        reviewInput()
    }

    private func reviewInput() {
        error = nil
        do { review = try T3PairingReview(input, code: code) }
        catch {
            // Leave what was read where it can be corrected.
            typesAddress = true
            self.error = T3PairingReview.message(for: error)
        }
    }

    /// A new address is a new decision, so it never inherits the last one's permission.
    private func clearReview() {
        cancelAttempt()
        review = nil
        paired = nil
        allowsHTTP = false
        error = nil
    }

    private func connect(_ review: T3PairingReview) {
        guard !isConnecting else { return }
        error = nil
        let destinations: [URL]
        do { destinations = try review.destinations(allowingHTTP: allowsHTTP) }
        catch { self.error = T3PairingReview.message(for: error); return }
        isConnecting = true
        let owner = UUID()
        attemptID = owner
        let existing = paired
        connectionTask = Task { @MainActor in
            defer {
                if attemptID == owner { isConnecting = false; connectionTask = nil }
            }
            do {
                let candidate: ConnectionConfiguration
                if let existing { candidate = existing }
                else {
                    candidate = try await exchange.exchangePairingCredential(
                        routes: destinations, credential: review.credential, clientLabel: "Botto"
                    ).configuration
                    // The code is spent. A later Connect for this review uses what it bought, even when this
                    // attempt was cancelled meanwhile.
                    if self.review == review { paired = candidate }
                    try Task.checkCancellation()
                    guard attemptID == owner else { return }
                }
                try Task.checkCancellation()
                guard attemptID == owner, scenePhase == .active else { return }
                if store.isDemo { store.leaveDemo() }
                var failure: (any Error)?
                let connected = await store.connect(candidate, onConnected: {
                    guard attemptID == owner, !Task.isCancelled, scenePhase == .active else { return }
                    BottoHaptics.shared.play(.celebration)
                }, onFailure: { failure = $0 })
                guard !Task.isCancelled, attemptID == owner else { return }
                if connected { dismiss() }
                else {
                    error = failure.map(T3PairingReview.message) ?? store.connectionError
                        ?? String(localized: "Couldn’t connect. Check that Botto is awake on your Mac and try again.")
                    if let failure, scenePhase == .active { BottoHaptics.shared.play(.failure(failure)) }
                }
            } catch is CancellationError {
                return
            } catch {
                // Even when the attempt was cancelled meanwhile, as when the app went to the background.
                if T3PairingReview.needsFreshLink(after: error) { retire(review, after: error) }
                guard !Task.isCancelled, attemptID == owner else { return }
                self.error = T3PairingReview.message(for: error)
                if scenePhase == .active { BottoHaptics.shared.play(.failure(error)) }
            }
        }
    }

    /// The code `spent` carries may already be redeemed, so neither its review nor any copy of the code
    /// is offered again. A typed address stays for a fresh code.
    private func retire(_ spent: T3PairingReview, after failure: any Error) {
        guard review == spent else { return }
        review = nil
        paired = nil
        allowsHTTP = false
        code = ""
        if T3PairingReview.isPairingLink(input) { input = "" }
        error = T3PairingReview.message(for: failure)
    }

    private func cancelAttempt() {
        attemptID = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        isConnecting = false
    }
}
