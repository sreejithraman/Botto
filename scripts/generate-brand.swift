#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
let scratch = root.appendingPathComponent(".artifacts/brand-generator")
try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)

@discardableResult
func run(_ arguments: [String], capture: Bool = false) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = arguments
    process.currentDirectoryURL = root
    let pipe = capture ? Pipe() : nil
    if let pipe { process.standardOutput = pipe }
    try process.run()
    let data = pipe?.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { exit(process.terminationStatus) }
    return data.map { String(decoding: $0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
}

let buildArguments = ["swift", "build", "--package-path", root.path,
                      "--scratch-path", scratch.appendingPathComponent("build").path]
try run(buildArguments + ["--target", "BottoCore"])
let bin = URL(fileURLWithPath: try run(buildArguments + ["--show-bin-path"], capture: true))
let aggregateObject = bin.appendingPathComponent("BottoCore.o")
let usesSwiftBuild = FileManager.default.fileExists(atPath: aggregateObject.path)
let moduleDirectory = usesSwiftBuild ? bin : bin.appendingPathComponent("Modules")
let objects = usesSwiftBuild ? [aggregateObject] : try FileManager.default.contentsOfDirectory(
    at: bin.appendingPathComponent("BottoCore.build"), includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "o" }.sorted { $0.path < $1.path }
let executable = scratch.appendingPathComponent("generate-brand")
try run(["swiftc", "-parse-as-library", "-I", moduleDirectory.path,
         root.appendingPathComponent("App/Design/BotAvatarGeometry.swift").path,
         root.appendingPathComponent("App/Design/BottoBrand.swift").path,
         root.appendingPathComponent("scripts/brand/GenerateBrand.swift").path]
        + objects.map(\.path) + ["-o", executable.path])
let generator = Process()
generator.executableURL = executable
generator.arguments = [root.path]
try generator.run()
generator.waitUntilExit()
exit(generator.terminationStatus)
