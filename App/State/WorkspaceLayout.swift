import SwiftUI

/// Uses the detail's allocated space. Geometry only changes allocation, never
/// session lifetime or modal presentation. Height and keyboard do not choose it.
struct WorkspaceLayout: Equatable {
    static let minimumChatWidth: CGFloat = 360
    static let minimumFileWidth: CGFloat = 320
    let compact: Bool
    let accessibilityText: Bool
    let workspaceWidth: CGFloat

    var pairsChatAndFile: Bool {
        !compact && !accessibilityText && workspaceWidth >= Self.minimumChatWidth + Self.minimumFileWidth + 1
    }

    func allocation(hasArtifact: Bool, browsingBots: Bool, expanded: Bool) -> WorkspacePaneAllocation {
        let width = max(0, workspaceWidth)
        guard hasArtifact, !browsingBots else {
            return WorkspacePaneAllocation(chatWidth: width, artifactWidth: 0)
        }
        guard !expanded, pairsChatAndFile else {
            return WorkspacePaneAllocation(chatWidth: 0, artifactWidth: width)
        }
        let artifactWidth = min(380, width - Self.minimumChatWidth - 1)
        return WorkspacePaneAllocation(chatWidth: width - artifactWidth - 1, artifactWidth: artifactWidth)
    }

    func transcriptExposed(browsingBots: Bool, hasArtifact: Bool, expanded: Bool,
                           rootCovered: Bool, localCovered: Bool, sceneActive: Bool,
                           compactShowsSidebar: Bool) -> Bool {
        sceneActive && !rootCovered && !localCovered && !(compact && (browsingBots || compactShowsSidebar))
            && allocation(hasArtifact: hasArtifact, browsingBots: browsingBots, expanded: expanded).chatVisible
    }

    /// A chat-only task remains the editing surface during native allocation
    /// handoff. Read evidence still requires actual geometry. A foreground file
    /// keeps the existing pane/compact coverage rules.
    func editorExposed(browsingBots: Bool, hasArtifact: Bool, expanded: Bool,
                       rootCovered: Bool, localCovered: Bool, sceneActive: Bool,
                       compactShowsSidebar: Bool) -> Bool {
        guard !browsingBots else { return false }
        if hasArtifact {
            return transcriptExposed(browsingBots: browsingBots, hasArtifact: true, expanded: expanded,
                rootCovered: rootCovered, localCovered: localCovered, sceneActive: sceneActive,
                compactShowsSidebar: compactShowsSidebar)
        }
        return sceneActive && !rootCovered && !localCovered
    }

}

struct WorkspacePaneAllocation: Equatable {
    let chatWidth: CGFloat
    let artifactWidth: CGFloat
    var chatVisible: Bool { chatWidth > 0 }
    var artifactVisible: Bool { artifactWidth > 0 }
    var paired: Bool { chatVisible && artifactVisible }
}
