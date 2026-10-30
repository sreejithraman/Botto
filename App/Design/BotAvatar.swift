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
    #if DEBUG
    @Environment(\.avatarMotionDisabledForTesting) private var forceStill
    @Environment(\.botMotionExperiment) private var experiment
    #endif

    private var still: Bool {
        #if DEBUG
        if forceStill { return true }
        #endif
        return reduceMotion || scenePhase != .active
    }

    var body: some View {
        let layout = fitsBody ? BotAvatarLayout(shape: profile.face.shape, size: size, imageSize: image?.size) : nil
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
                #if DEBUG
                if let experiment, experiment.style != .original, motion != .still {
                    if experiment.followsLiveActivity {
                        BotAvatarMotion(profile: profile, size: size,
                            presentation: resolvedPresentation, style: experiment.style, still: still, minimumCueTop: minimumCueTop)
                    } else {
                        BotMotionPrototypeFace(profile: profile, size: size, experiment: experiment, still: still)
                    }
                } else {
                    if experiment?.style == .original || motion == .still {
                        face(motion: motion.honoring(reduceMotion: still))
                    } else {
                        BotAvatarMotion(profile: profile, size: size, presentation: resolvedPresentation, still: still, minimumCueTop: minimumCueTop)
                    }
                }
                #else
                if motion == .still {
                    BotAvatarMark(profile: profile, size: size)
                } else {
                    BotAvatarMotion(profile: profile, size: size, presentation: resolvedPresentation, still: still, minimumCueTop: minimumCueTop)
                }
                #endif
            }
        }
        .frame(width: size, height: size)
        .offset(y: layout?.fittedVerticalOffset ?? 0)
        .frame(width: size, height: layout?.fittedHeight ?? size)
        .accessibilityHidden(true)
    }

    private var resolvedPresentation: BotAvatarPresentation {
        if let presentation { return presentation }
        if case .working(let start) = motion {
            return .init(activity: .working, enteredAt: start, workStartedAt: start)
        }
        return .init(activity: .idle, enteredAt: .distantPast)
    }

    @ViewBuilder private func face(motion: BotFaceMotion) -> some View {
        switch motion {
        case .still:
            BotAvatarMark(profile: profile, size: size)
        case .idle:
            let schedule = BotBlinkSchedule(seed: profile.id)
            TimelineView(schedule) { context in
                BotAvatarMark(profile: profile, size: size, pose: schedule.isShut(at: context.date) ? .blink : .rest)
            }
        case .working(let since):
            let schedule = BotWorkingSchedule(start: since, blink: BotBlinkSchedule(seed: profile.id))
            TimelineView(schedule) { context in
                BotAvatarMark(profile: profile, size: size, pose: schedule.pose(at: context.date))
            }
        }
    }
}

/// A single frame; only the mark moves, never its layout or surrounding controls.
/// Kept internal so deterministic renders use the same frame as every timeline.
struct BotAvatarMark: View {
    let profile: BotProfile
    let size: CGFloat
    var pose: BotFacePose = .rest
    var animatedEyes: BotAvatarExpression.Geometry? = nil

    private var eyeGeometry: BotAvatarExpression.Geometry {
        if let animatedEyes { return animatedEyes }
        return BotAvatarExpression.resolve(profile.appearance?.expression).geometry
    }

    var body: some View {
        ZStack {
            BotAvatarBody(shape: profile.face.shape).fill(Color.botBody(profile.face.color))
            let geometry = eyeGeometry
            let placement = BotAvatarFacePlacement(shape: profile.face.shape, geometry: geometry)
            HStack(spacing: size * 0.1 * geometry.split / 15.46) {
                eye(geometry.left)
                eye(geometry.right)
            }
            .scaleEffect(placement.scale)
            .offset(x: size * (placement.x + pose.gazeX), y: size * (placement.y + pose.gazeY))
        }
        .rotationEffect(.degrees(pose.roll))
        .frame(width: size, height: size)
    }

    private func eye(_ eye: BotAvatarExpression.Eye) -> some View {
        Capsule().fill(Color.botEyes(on: profile.face.color))
            .frame(width: size * 0.075 * eye.width / 0.186, height: size * 0.22 * eye.height / 0.412 * pose.lid)
            .rotationEffect(.degrees(-18 + eye.tilt))
    }
}

#if DEBUG
private struct AvatarMotionTestKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    var avatarMotionDisabledForTesting: Bool {
        get { self[AvatarMotionTestKey.self] }
        set { self[AvatarMotionTestKey.self] = newValue }
    }
}
#endif
