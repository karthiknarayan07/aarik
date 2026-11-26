import AarikCore
import Foundation
import MediaEngine
import MediaTestSupport

// Developer-only command line for hand-checking clips. Not shipped with the app.

let usage = """
    usage:
      devtool fixture <out> [--sdr] [--seconds N] [--size WxH] [--camera-metadata]
      devtool inspect <file>
      devtool downscale <in> <out> [--short-side N] [--max-fps F] [--bitrate B] [--h264]
    """

func printError(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}

func fail(_ message: String, showUsage: Bool = false) -> Never {
    printError(message)
    if showUsage { printError(usage) }
    exit(1)
}

func friendlyMessage(for error: Error) -> String {
    switch error as? DownscaleError {
    case .outputExists?: return "The output file already exists; refusing to overwrite it."
    case .sourceAlreadySmall?: return "Source is already at or below the target size; nothing to do."
    case .unsupportedSource(let reason)?: return "This kind of video is not supported (\(reason))."
    case .encoderFailed(let reason)?: return "The video encoder failed: \(reason)"
    case .stalled?: return "The encoder stopped responding."
    case nil: return "\(error.localizedDescription)"
    }
}

func runFixture(_ args: [String]) async throws {
    var paths: [String] = []
    var options = ClipOptions()
    var index = 0
    while index < args.count {
        let arg = args[index]
        index += 1
        if arg == "--sdr" {
            options.hdr = .sdr
        } else if arg == "--seconds" {
            guard index < args.count, let seconds = Double(args[index]), seconds > 0 else {
                fail("--seconds needs a positive number")
            }
            options.seconds = seconds
            index += 1
        } else if arg == "--size" {
            let parts = index < args.count ? args[index].split(separator: "x").compactMap { Int($0) } : []
            guard parts.count == 2, parts.allSatisfy({ $0 > 0 }) else { fail("--size needs WIDTHxHEIGHT") }
            options.width = parts[0]
            options.height = parts[1]
            index += 1
        } else if arg == "--camera-metadata" {
            options.quickTimeMetadata = [
                "com.apple.quicktime.make": "TestMake",
                "com.apple.quicktime.model": "TestModel",
                "com.apple.quicktime.software": "1.0",
                "com.apple.quicktime.creationdate": "2020-01-02T03:04:05+0000",
                "com.apple.quicktime.location.ISO6709": "+10.0000+20.0000+5.000/",
            ]
        } else if arg.hasPrefix("--") {
            fail("Unknown option \(arg)", showUsage: true)
        } else {
            paths.append(arg)
        }
    }
    guard paths.count == 1 else { fail("fixture needs exactly one output path", showUsage: true) }
    let destination = URL(fileURLWithPath: paths[0])
    if FileManager.default.fileExists(atPath: destination.path) {
        fail("The output file already exists; refusing to overwrite it.")
    }
    let made = try await FixtureFactory.makeClip(options)
    try FileManager.default.copyItem(at: made, to: destination)
    print("Wrote \(destination.path)")
}

func runInspect(_ args: [String]) async throws {
    guard args.count == 1 else { fail("inspect needs exactly one file", showUsage: true) }
    let inventory = try await MediaInspector().inventory(of: URL(fileURLWithPath: args[0]))
    for item in inventory.items {
        print("\(item.category.rawValue)  \(item.displayName): \(item.value)")
    }
}

func runDownscale(_ args: [String]) async throws -> Int32 {
    var paths: [String] = []
    var spec = DownscaleSpec()
    var index = 0
    func value(for flag: String) -> String {
        index += 1
        guard index < args.count else { fail("\(flag) needs a value", showUsage: true) }
        return args[index]
    }
    while index < args.count {
        let arg = args[index]
        switch arg {
        case "--short-side":
            guard let n = Int(value(for: arg)), n > 0 else { fail("--short-side needs a positive whole number") }
            spec.targetShortSide = n
        case "--max-fps":
            guard let f = Double(value(for: arg)), f > 0 else { fail("--max-fps needs a positive number") }
            spec.maxFrameRate = f
        case "--bitrate":
            guard let b = Int(value(for: arg)), b > 0 else { fail("--bitrate needs a positive whole number") }
            spec.averageBitRate = b
        case "--h264":
            spec.codec = .h264Compatible
        default:
            if arg.hasPrefix("--") { fail("Unknown option \(arg)", showUsage: true) }
            paths.append(arg)
        }
        index += 1
    }
    guard paths.count == 2 else { fail("downscale needs an input and an output path", showUsage: true) }
    let source = URL(fileURLWithPath: paths[0])
    let output = URL(fileURLWithPath: paths[1])

    do {
        try await VideoDownscaler().downscale(source: source, output: output, spec: spec) { fraction in
            let percent = Int((min(max(fraction, 0), 1) * 100).rounded())
            FileHandle.standardError.write(Data("\rDownscaling… \(percent)%".utf8))
        }
        FileHandle.standardError.write(Data("\n".utf8))
    } catch {
        FileHandle.standardError.write(Data("\n".utf8))
        fail(friendlyMessage(for: error))
    }

    let before = try await MediaInspector().inventory(of: source)
    let after = try await MediaInspector().inventory(of: output)
    let report = MetadataDiff.report(source: before, output: after)

    print("Kept (\(report.kept.count))")
    for item in report.kept { print("  \(item.displayName)") }
    print("Changed (\(report.changed.count))")
    for change in report.changed { print("  \(change.displayName): \(change.from) → \(change.to)") }
    print("Lost (\(report.lost.count))")
    for item in report.lost { print("  \(item.displayName)") }
    return report.isLossless ? 0 : 2
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard let command = arguments.first else { fail("Missing command.", showUsage: true) }
let rest = Array(arguments.dropFirst())

do {
    switch command {
    case "fixture": try await runFixture(rest)
    case "inspect": try await runInspect(rest)
    case "downscale": exit(try await runDownscale(rest))
    default: fail("Unknown command \(command)", showUsage: true)
    }
} catch {
    fail(friendlyMessage(for: error))
}
