import Foundation

/// The shared bound for a condition that a passing test always reaches. A hosted runner has held the
/// main actor for 26 seconds, so this stops a hang rather than measuring speed. Assertions about elapsed
/// time, an expected timeout, or something that must not happen keep their own limits.
let readinessLimit = Duration.seconds(45)
/// `readinessLimit` in seconds, for XCTest waits such as `waitForExistence(timeout:)`.
let readinessTimeout: TimeInterval = readinessLimit / .seconds(1)
