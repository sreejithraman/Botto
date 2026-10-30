import Darwin
import Foundation

@MainActor enum NativeAccessibilityRuntime {
    private static var enabled = false

    static func enable() throws {
        #if targetEnvironment(simulator)
        guard !enabled else { return }
        let root = ProcessInfo.processInfo.environment["IPHONE_SIMULATOR_ROOT"] ?? ""
        let path = root + "/usr/lib/libAccessibility.dylib"
        guard let library = dlopen(path, RTLD_NOW | RTLD_LOCAL) else {
            throw SetupError.unavailable(path)
        }
        guard let readSymbol = dlsym(library, "_AXSAutomationEnabled"),
              let writeSymbol = dlsym(library, "_AXSSetAutomationEnabled") else {
            dlclose(library)
            throw SetupError.unavailable("Simulator accessibility automation symbols")
        }
        let read = unsafeBitCast(readSymbol, to: (@convention(c) () -> Int32).self)
        let write = unsafeBitCast(writeSymbol, to: (@convention(c) (Int32) -> Void).self)
        let previous = read()
        // SwiftUI's in-process accessibility tree requires automation in this
        // test host. Keep the library loaded for the process-exit restoration.
        guard atexit_b({ write(previous) }) == 0 else {
            dlclose(library)
            throw SetupError.unavailable("Simulator accessibility restoration")
        }
        write(1)
        guard read() != 0 else { throw SetupError.couldNotEnable }
        enabled = true
        #endif
    }

    private enum SetupError: Error {
        case unavailable(String)
        case couldNotEnable
    }
}
