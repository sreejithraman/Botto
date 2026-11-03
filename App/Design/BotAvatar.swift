import SwiftUI
import BottoCore

/// All bot surfaces share the server image and the same profile-ID-derived fallback.
struct BotAvatar: View {
    let profile: BotProfile
    var image: UIImage?
    var size: CGFloat = 56
    var motion: BotFaceMotion = .idle
    var presentation: BotAvatarPresentation? = nil
    /// Uses the body's height for layout while activity cues remain free to overflow.
    var fitsBody = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG || BOTTO_INTERNAL_TOOLS
    @Environment(\.avatarMotionDisabledForTesting) private var forceStill
    @Environment(\.botMotionExperiment) private var experiment
    @Environment(\.botMotionActivity) private var observedActivity
    #endif

    private var still: Bool {
        #if DEBUG || BOTTO_INTERNAL_TOOLS
        if forceStill { return true }
        #endif
        return reduceMotion || scenePhase != .active
    }

    var body: some View {
        let layout = fitsBody ? BotAvatarLayout(shape: profile.face.shape, size: size, imageSize: image?.size,
            geometry: profile.appearance?.geometry) : nil
        let minimumCueTop = layout.map { Double($0.bodyBounds.minY / size) - 0.5 - 0.14 }
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().frame(width: size, height: size)
                    .overlay {
                        if resolvedPresentation.activity == .offline {
                            BotAvatarActivityCue(shape: .squircle, size: size, activity: .offline, minimumCueTop: minimumCueTop)
                        }
                    }
            } else {
                BotAvatarMotion(profile: profile, size: size, presentation: resolvedPresentation,
                                still: still || motion == .still, minimumCueTop: minimumCueTop)
            }
        }
        .frame(width: size, height: size)
        .offset(y: layout?.fittedVerticalOffset ?? 0)
        .frame(width: size, height: layout?.fittedHeight ?? size)
        .accessibilityHidden(true)
    }

    private var resolvedPresentation: BotAvatarPresentation {
        #if DEBUG || BOTTO_INTERNAL_TOOLS
        if let experiment, motion != .still, !experiment.followsLiveActivity {
            return .init(activity: observedActivity ?? experiment.activity, enteredAt: experiment.triggeredAt,
                         workStartedAt: experiment.workStartedAt)
        }
        #endif
        if let presentation { return presentation }
        if case .working(let start) = motion {
            return .init(activity: .working, enteredAt: start, workStartedAt: start)
        }
        return .init(activity: .idle, enteredAt: .distantPast)
    }

}

struct BotAvatarMark: View {
    let profile: BotProfile
    let size: CGFloat
    var body: some View {
        BotAvatarMotion(profile: profile, size: size,
                        presentation: .init(activity: .idle, enteredAt: .distantPast), still: true)
    }
}

#if DEBUG || BOTTO_INTERNAL_TOOLS
private struct AvatarMotionTestKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var avatarMotionDisabledForTesting: Bool {
        get { self[AvatarMotionTestKey.self] }
        set { self[AvatarMotionTestKey.self] = newValue }
    }
}
#endif
