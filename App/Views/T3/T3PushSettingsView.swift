import SwiftUI
import BottoCore

struct T3PushSettingsView: View {
    let store: AppStore
    @Environment(\.openURL) private var openURL
    private enum CodePurpose { case enroll, updateAddress }
    @State private var codePurpose: CodePurpose?
    @State private var code = ""

    private var coordinator: T3PushCoordinator { store.t3Push }
    private var scope: T3PushScope? { store.t3PushScope }
    private var pairing: T3PushPairing? { coordinator.pairing(scope) }
    private var hasPendingRemoval: Bool { coordinator.hasPendingRemoval(scope) }

    var body: some View {
        Form {
            Section {
                Toggle("Space notifications", isOn: Binding(
                    get: { pairing?.registration.target != nil && pairing?.confirmed == true },
                    set: { enabled in
                        if enabled { codePurpose = .enroll }
                        else if let scope { Task { await coordinator.disable(scope: scope) } }
                    }
                ))
                .accessibilityIdentifier("t3-push-toggle")
                .disabled(scope == nil || coordinator.isBusy || (pairing != nil && pairing?.confirmed == false))

                if pairing != nil || hasPendingRemoval {
                    Button("Update Mac Address") { codePurpose = .updateAddress }
                        .disabled(coordinator.isBusy || codePurpose != nil)
                }
                if let codePurpose, let scope {
                    let updatingAddress = codePurpose == .updateAddress
                    SecureField("Notification code from your Mac", text: $code)
                        .textContentType(.password)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Button(updatingAddress ? "Update Address" : "Enable Notifications") {
                        Task {
                            if updatingAddress { await coordinator.updateMacAddress(code: code, scope: scope) }
                            else { await coordinator.enable(code: code, scope: scope) }
                            if coordinator.notice == nil || (!updatingAddress && coordinator.pairing(scope) != nil) {
                                self.codePurpose = nil
                            }
                            code = ""
                        }
                    }
                    .disabled(code.isEmpty || coordinator.isBusy)
                    Button("Cancel", role: .cancel) {
                        self.codePurpose = nil
                        code = ""
                    }
                    .disabled(coordinator.isBusy)
                }
                if hasPendingRemoval || pairing?.confirmed == false {
                    Button(pairing?.confirmed == false ? "Retry Setup" : "Retry Removal") {
                        Task { await coordinator.resume(scope: scope) }
                    }
                    .disabled(coordinator.isBusy)
                    if pairing?.confirmed == false, let scope {
                        Button("Turn Off", role: .destructive) { Task { await coordinator.disable(scope: scope) } }
                            .disabled(coordinator.isBusy)
                    }
                }
            } footer: {
                if scope == nil {
                    Text("Connect to your Mac to set up notifications.")
                } else if pairing == nil {
                    Text("Copy a notification code from Botto’s settings on your Mac to get alerts for completions and requests.")
                } else {
                    Text("Get alerts when Botto finishes work or needs a response in a Space.")
                }
            }

            if let notice = coordinator.notice { Section { Text(notice) } }
            Button("Open iOS Notification Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { openURL(url) }
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
    }
}
