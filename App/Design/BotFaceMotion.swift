import Foundation

enum BotFaceMotion: Equatable, Sendable {
    case still, idle
    case working(since: Date)
    func honoring(reduceMotion: Bool) -> Self { reduceMotion ? .still : self }
}
