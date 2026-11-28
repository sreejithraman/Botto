import Foundation
import Testing
@testable import BottoMac

@MainActor
struct MacUpdateChannelSettingsTests {
    @Test func stableBuildDefaultsToStableChannel() {
        let suite = "com.sree.botto.mac.tests.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = MacUpdateChannelSettings(defaults: defaults, defaultIncludesBeta: false)
        #expect(settings.includesBetaUpdates == false)
        #expect(settings.selectedChannels.isEmpty)
    }

    @Test func betaBuildDefaultsToBetaChannelWithoutPriorPreference() {
        let suite = "com.sree.botto.mac.tests.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = MacUpdateChannelSettings(defaults: defaults, defaultIncludesBeta: true)
        #expect(settings.includesBetaUpdates == true)
        #expect(settings.selectedChannels == ["beta"])
    }

    @Test func explicitPreferenceOverridesBundleDefaultAndResetsCycle() {
        let suite = "com.sree.botto.mac.tests.updates.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = MacUpdateChannelSettings(defaults: defaults, defaultIncludesBeta: true)
        var resetCount = 0
        settings.setIncludesBetaUpdates(false) { resetCount += 1 }
        settings.setIncludesBetaUpdates(false) { resetCount += 1 }

        #expect(resetCount == 1)
        #expect(settings.includesBetaUpdates == false)
        #expect(settings.selectedChannels.isEmpty)

        let reloaded = MacUpdateChannelSettings(defaults: defaults, defaultIncludesBeta: true)
        #expect(reloaded.includesBetaUpdates == false)
        #expect(reloaded.selectedChannels.isEmpty)
    }

    @Test func updaterIsDisabledInsideXCTestEnvironment() {
        #expect(MacUpdateAvailability.isEnabled(environment: ["XCTestConfigurationFilePath": "/tmp/test.xctestconfiguration"]) == false)
        #expect(MacUpdateAvailability.isEnabled(environment: ["BOTTO_DISABLE_UPDATES": "1"]) == false)
    }
}
