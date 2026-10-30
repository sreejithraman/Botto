// Native PKCE/system-browser flow adapted from Hermex.
// Copyright (c) 2026 Uzair Ansar. MIT license: LICENSES/Hermex.txt.
import AuthenticationServices
import Foundation
import BottoCore
import Security
import UIKit

/// One browser attempt for a destination the user has already reviewed.
/// The parent owns saving and must cancel its Task when leaving the connection form.
@MainActor final class BrowserSignIn: NSObject, ASWebAuthenticationPresentationContextProviding {
    enum Failure: Error, LocalizedError {
        case unavailable, invalidCallback, timedOut, randomUnavailable
        var errorDescription: String? {
            switch self {
            case .unavailable: "Couldn’t open browser sign-in. Try again from the connection form."
            case .invalidCallback: "Sign-in did not return a matching authorization code. Start again."
            case .timedOut: "Browser sign-in expired. Start again."
            case .randomUnavailable: "Couldn’t securely start sign-in. Try again."
            }
        }
    }

    private var browser: ASWebAuthenticationSession?
    private var browserResult: CheckedContinuation<Void, any Error>?
    private var receiver: LoopbackSignInReceiver?
    private var exchange: NativeSignInExchange?
    private var terminalError: (any Error)?
    private var presentationWindow: UIWindow?

    static func authenticate(serverURL: URL, connectionHeaders: [String: String] = [:]) async throws -> ConnectionConfiguration {
        let attempt = BrowserSignIn()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await attempt.run(serverURL: serverURL, connectionHeaders: connectionHeaders)
        } onCancel: {
            Task { @MainActor in attempt.abort(CancellationError()) }
        }
    }

    private func run(serverURL: URL, connectionHeaders: [String: String]) async throws -> ConnectionConfiguration {
        let timeout = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(180)) }
            catch { return }
            self?.abort(Failure.timedOut)
        }
        defer {
            timeout.cancel()
            receiver?.stop()
            browser?.cancel()
            browser = nil
            exchange?.close()
            exchange = nil
            presentationWindow = nil
        }
        do {
            try check()
            let exchange = try NativeSignInExchange(serverURL: serverURL, connectionHeaders: connectionHeaders)
            self.exchange = exchange
            try await exchange.probe()
            try check()
            let verifier = try Self.randomURLSafe(32)
            let state = try Self.randomURLSafe(32)
            let receiver = LoopbackSignInReceiver(state: state)
            self.receiver = receiver
            let port = try await receiver.start()
            try check()
            let authorization = try exchange.authorizationURL(verifier: verifier, state: state, loopbackPort: port)
            try await present(authorization)
            try check()
            guard let code = receiver.code else { throw Failure.invalidCallback }
            receiver.stop()
            let configuration = try await exchange.configuration(code: code, verifier: verifier)
            try check()
            return configuration
        } catch {
            if let terminalError { throw terminalError }
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }

    private func present(_ url: URL) async throws {
        try check()
        presentationWindow = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        guard presentationWindow != nil else { throw Failure.unavailable }
        try await withCheckedThrowingContinuation { continuation in
            browserResult = continuation
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "botto-signin") { [weak self] callback, error in
                Task { @MainActor in self?.browserCompleted(callback: callback, error: error) }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            browser = session
            if !session.start() { finishBrowser(.failure(Failure.unavailable)) }
        }
    }

    private func browserCompleted(callback: URL?, error: (any Error)?) {
        if let terminalError { return finishBrowser(.failure(terminalError)) }
        if let error {
            if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                return finishBrowser(.failure(CancellationError()))
            }
            return finishBrowser(.failure(Failure.unavailable))
        }
        // This scheme only closes the sheet. Authorization comes from the loopback code.
        guard callback?.absoluteString == "botto-signin://done", receiver?.code != nil else {
            return finishBrowser(.failure(Failure.invalidCallback))
        }
        finishBrowser(.success(()))
    }

    private func finishBrowser(_ result: Result<Void, any Error>) {
        let continuation = browserResult
        browserResult = nil
        continuation?.resume(with: result)
    }

    private func abort(_ error: any Error) {
        guard terminalError == nil else { return }
        terminalError = error
        receiver?.stop()
        exchange?.close()
        browser?.cancel()
        finishBrowser(.failure(error))
    }

    private func check() throws {
        if let terminalError { throw terminalError }
        try Task.checkCancellation()
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        // A foreground anchor is captured before starting the authentication session.
        presentationWindow ?? ASPresentationAnchor()
    }

    private static func randomURLSafe(_ count: Int) throws -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        guard SecRandomCopyBytes(kSecRandomDefault, count, &bytes) == errSecSuccess else { throw Failure.randomUnavailable }
        return base64URL(Data(bytes))
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
