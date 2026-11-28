import Combine
import Foundation
import Sparkle
import SwiftUI

enum MacUpdateAvailability {
    static func isEnabled(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if environment["XCTestConfigurationFilePath"] != nil { return false }
        if environment["BOTTO_DISABLE_UPDATES"] == "1" { return false }
        guard let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let key = bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !key.contains("PENDING_")
        else { return false }
        return true
    }

    static func bundleDefaultsToBeta(bundle: Bundle = .main) -> Bool {
        if let channel = bundle.object(forInfoDictionaryKey: "BottoUpdateChannel") as? String,
           channel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "beta" {
            return true
        }
        if let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
           shortVersion.localizedCaseInsensitiveContains("beta") {
            return true
        }
        return false
    }
}

@MainActor
final class MacUpdateChannelSettings: NSObject, ObservableObject, SPUUpdaterDelegate {
    static let includesBetaUpdatesKey = "BottoIncludeBetaUpdates"

    @Published private(set) var includesBetaUpdates: Bool

    private let defaults: UserDefaults

    init(
        defaults: UserDefaults = .standard,
        defaultIncludesBeta: Bool = MacUpdateAvailability.bundleDefaultsToBeta()
    ) {
        self.defaults = defaults
        if defaults.object(forKey: Self.includesBetaUpdatesKey) != nil {
            includesBetaUpdates = defaults.bool(forKey: Self.includesBetaUpdatesKey)
        } else {
            includesBetaUpdates = defaultIncludesBeta
        }
        super.init()
    }

    var selectedChannels: Set<String> {
        includesBetaUpdates ? ["beta"] : []
    }

    func setIncludesBetaUpdates(
        _ includesBetaUpdates: Bool,
        resetUpdateCycle: () -> Void = { }
    ) {
        guard self.includesBetaUpdates != includesBetaUpdates else { return }
        self.includesBetaUpdates = includesBetaUpdates
        defaults.set(includesBetaUpdates, forKey: Self.includesBetaUpdatesKey)
        resetUpdateCycle()
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        selectedChannels
    }
}

struct MacUpdateSettingsSection: View {
    @ObservedObject var settings: MacUpdateChannelSettings
    let updater: SPUUpdater
    let checksEnabled: Bool

    var body: some View {
        Section("Updates") {
            Toggle(
                "Check for updates automatically",
                isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                )
            )
            .disabled(!checksEnabled)
            Toggle(
                "Include beta updates",
                isOn: Binding(
                    get: { settings.includesBetaUpdates },
                    set: { newValue in
                        settings.setIncludesBetaUpdates(newValue) {
                            updater.resetUpdateCycleAfterShortDelay()
                        }
                    }
                )
            )
            .accessibilityIdentifier("include-beta-updates")
            Text("Beta builds arrive earlier and may be less stable. Turn this off to stay on stable releases.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Check for Updates…") {
                updater.checkForUpdates()
            }
            .disabled(!checksEnabled || !updater.canCheckForUpdates)
        }
    }
}
