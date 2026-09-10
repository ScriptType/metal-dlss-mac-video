import CoreMedia
import CryptoKit
import DLSSMedia
import DLSSMLX
import Foundation
import Metal

/// Offline diagnostic capture. This deliberately bypasses playback scheduling,
/// decoder assumptions and RGBA16F packing; it is not a throughput benchmark.
enum FrameReferenceSequence {
    struct Time: Codable, Equatable {
        let value: Int64
        let timescale: Int32
        var cm: CMTime { CMTime(value: value, timescale: timescale) }
        var json: [String: Any] { ["value": value, "timescale": timescale] }
    }
    struct InputFrame: Decodable {
        let sourceFrameIndex: UInt64
        let path, sha256: String
        let pts, duration: Time
    }
    struct Manifest: Decodable {
        let schemaVersion, width, height: Int
        let layout, primaries, transfer, units: String
        let frames: [InputFrame]
    }
    struct Input {
        let url: URL
        let data: Data
        let manifest: Manifest
        let provenance: [String: Any]
        let paths: [URL]
        let frameBytes: Int
    }
    struct Failure: Error, LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let layout = "RGB float32 little-endian top-to-bottom"
    static let maximumBytes: UInt64 = 2 * 1024 * 1024 * 1024

    static func run(_ arguments: [String]) async throws {
        if arguments == ["--reference-sequence-self-test"] { try selfTest(); return }
        if arguments.count == 2, arguments[0] == "--reference-sequence-validate" {
            let input = try preflight(URL(fileURLWithPath: arguments[1]))
            print("reference-sequence preflight passed frames=\(input.manifest.frames.count) frameBytes=\(input.frameBytes) manifestSHA256=\(digest(input.data)); no model or GPU work")
            return
        }
        let allowed = Set(["--reference-sequence", "--output", "--model", "--frames", "--width", "--height",
                           "--strength", "--colour-strength", "--maximum-luminance-ratio", "--reference-white",
                           "--maximum-output-bytes", "--motion"])
        var options = [String: String]()
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            guard allowed.contains(key), index + 1 < arguments.count, options[key] == nil else {
                throw Failure("Unknown, repeated or missing reference-sequence option: \(key)")
            }
            options[key] = arguments[index + 1]; index += 2
        }
        guard let inputPath = options["--reference-sequence"], let outputPath = options["--output"],
              let modelPath = options["--model"] else {
            throw Failure("Required: --reference-sequence MANIFEST --output NEW_DIRECTORY --model PACKAGE")
        }
        func integer(_ key: String, _ fallback: Int) throws -> Int {
            guard let value = Int(options[key] ?? String(fallback)) else { throw Failure("Invalid \(key)") }
            return value
        }
        func scalar(_ key: String, _ fallback: Float) throws -> Float {
            guard let value = Float(options[key] ?? String(fallback)), value.isFinite else { throw Failure("Invalid \(key)") }
            return value
        }
        let width = try integer("--width", 160), height = try integer("--height", 96)
        let strength = try scalar("--strength", 1), colour = try scalar("--colour-strength", 1)
        let ratio = try scalar("--maximum-luminance-ratio", 2), white = try scalar("--reference-white", 203)
        let budget = try integer("--maximum-output-bytes", Int(maximumBytes))
        guard width > 0, height > 0, width <= 512 * 288 / height,
              (0...1).contains(strength), (0...1).contains(colour), ratio >= 1, white > 0,
              budget > 0, UInt64(budget) <= maximumBytes,
              let motion = MediaMotion(rawValue: options["--motion"] ?? "automatic") else {
            throw Failure("Invalid capture settings: processing at most512×288 pixels; output budget at most2GiB")
        }
        // Every input payload is checked before any model/GPU allocation. Read
        // again immediately before processing, detecting edits after preflight.
        let input = try preflight(URL(fileURLWithPath: inputPath))
        let count = try integer("--frames", input.manifest.frames.count)
        guard count > 0, count <= input.manifest.frames.count, count <= 120 else {
            throw Failure("Capture count must be1...120 and available in the manifest")
        }
        let floatBytes = UInt64(input.frameBytes) * UInt64(count) * 4
        let metadataAllowance: UInt64 = 4 * 1024 * 1024
        guard floatBytes + metadataAllowance <= UInt64(budget) else {
            throw Failure("Four-view float payload plus bounded metadata exceeds output budget")
        }
        let model = URL(fileURLWithPath: modelPath).standardizedFileURL.resolvingSymlinksInPath()
        let modelFiles = try modelInventory(model)
        let output = URL(fileURLWithPath: outputPath).standardizedFileURL
        guard !FileManager.default.fileExists(atPath: output.path) else { throw Failure("Output directory already exists") }
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try input.data.write(to: output.appendingPathComponent("input-manifest.json"), options: .atomic)
        let started = ContinuousClock.now
        var records = [[String: Any]]()
        var report: [String: Any] = [
            "schemaVersion": 1, "complete": false,
            "inputManifestSHA256": digest(input.data), "inputManifestPath": input.url.path,
            "inputManifestCopy": "input-manifest.json", "provenance": input.provenance,
            "width": input.manifest.width, "height": input.manifest.height, "layout": layout,
            "views": ["original", "proxy", "identity", "enhanced"],
            "referenceDomain": ["primaries": "BT.2020", "transfer": "linear", "units": "cd/m2"],
            "proxyDomain": ["primaries": "BT.709", "transfer": "sRGB", "units": "normalized0...1"],
            "requestedFrames": count, "maximumFrames": 120, "maximumOutputBytes": budget,
            "rawPayloadBytes": floatBytes, "metadataAllowanceBytes": metadataAllowance,
            "sourceIdentity": "sha256:\(digest(input.data))", "generation": 1,
            "settings": ["processingWidth": width, "processingHeight": height, "strength": strength,
                "colourStrength": colour, "maximumLuminanceRatio": ratio, "referenceWhiteNits": white,
                "temporal": true, "motionRequested": motion.rawValue, "sceneCutThreshold": 0.3,
                "precision": "float16", "mlxCacheBytes": 256 * 1024 * 1024],
            "model": ["path": model.path, "files": modelFiles],
            "runtime": runtimeProvenance(),
            "startup": "Cold history at the first supplied frame; no implicit preroll or omitted warmup",
            "limits": ["One persistent model, sequential processing and synchronous per-view readback/write",
                "Specific cut/reset cause and selected automatic flow backend are unavailable in the public result",
                "Stage wall timings include completed work; readback and disk overhead make this unsuitable as a throughput benchmark",
                "Raw working references precede RGBA16F output packing and display mapping",
                "No calibrated HDR, physical presentation, sustained A/V or temporal-quality qualification"]
        ]
        func publish() throws {
            report["frames"] = records
            report["completedFrames"] = records.count
            report["elapsedSeconds"] = seconds(started)
            try writeJSON(report, output.appendingPathComponent("manifest.json"))
        }
        try publish()
        do {
            guard let device = MTLCreateSystemDefaultDevice() else { throw Failure("No Metal device") }
            report["device"] = ["name": device.name, "registryID": device.registryID,
                                "unifiedMemory": device.hasUnifiedMemory]
            try MLXRuntimeDiagnostics.setCacheLimitBytes(256 * 1024 * 1024)
            MLXRuntimeDiagnostics.resetPeakMemory()
            let processor = try NativeHDRProcessor(configuration: .init(modelURL: model,
                processingWidth: width, processingHeight: height, strength: strength, colorStrength: colour,
                maximumLuminanceRatio: ratio, temporal: true, motion: motion, precision: .float16))
            for ordinal in 0..<count {
                try Task.checkCancellation()
                let source = input.manifest.frames[ordinal]
                let path = try contained(source.path, in: input.url.deletingLastPathComponent())
                guard path == input.paths[ordinal] else { throw Failure("Source path changed after preflight") }
                let bytes = try payload(path, source.sha256, input.frameBytes)
                // Original is already linear BT.2020 nits. No YCbCr importer or
                // nominal timestamp synthesis is involved; matrix is unused.
                let original = try MLXVideoFrame(rgb: bytes, width: input.manifest.width, height: input.manifest.height)
                let metadata = MLXHDRFrameMetadata(time: source.pts.cm, duration: source.duration.cm,
                    sourceID: "sha256:\(digest(input.data))", streamID: 1, frameIndex: source.sourceFrameIndex,
                    generation: 1, crop: CGRect(x: 0, y: 0, width: input.manifest.width, height: input.manifest.height),
                    color: .init(transfer: .linear, primaries: .bt2020, fullRange: true,
                        referenceWhiteNits: white, sourceTags: ["rawDomain": "linearBT2020nits",
                            "matrix": "not used for direct RGB", "provenance": "input-manifest.json"]))
                let result = try await processor.process(MLXHDRFrame(original: original, metadata: metadata))
                guard result.usedModel == (strength > 0), result.metadata.time == source.pts.cm,
                      result.metadata.duration == source.duration.cm, result.metadata.frameIndex == source.sourceFrameIndex else {
                    throw Failure("Processor result provenance differs from submitted source")
                }
                let stem = String(format: "frame-%04d", ordinal)
                let staging = output.appendingPathComponent(".\(stem)-staging", isDirectory: true)
                try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: false)
                var views = [String: Any]()
                for (name, frame) in [("original", result.original), ("proxy", result.proxy),
                                      ("identity", result.identity), ("enhanced", result.enhanced)] {
                    guard frame.width == input.manifest.width, frame.height == input.manifest.height else {
                        throw Failure("Diagnostic view geometry differs from source")
                    }
                    let data = frame.copyRGBData()
                    let statistics = try floatStatistics(data, expectedBytes: input.frameBytes)
                    if name == "original", digest(data) != source.sha256.lowercased() {
                        throw Failure("Retained original differs from source RGB32F bytes")
                    }
                    let filename = "\(name).rgb32f"
                    try data.write(to: staging.appendingPathComponent(filename), options: .atomic)
                    views[name] = ["path": "\(stem)/\(filename)", "sha256": digest(data), "bytes": data.count,
                        "statistics": statistics]
                }
                let previous = ordinal > 0 ? input.manifest.frames[ordinal - 1] : nil
                let memory = MLXRuntimeDiagnostics.memorySnapshot()
                let record: [String: Any] = ["ordinal": ordinal, "sourceFrameIndex": source.sourceFrameIndex,
                    "inputPath": source.path, "inputSHA256": source.sha256.lowercased(),
                    "pts": source.pts.json, "duration": source.duration.json, "generation": 1,
                    "usedModel": result.usedModel, "historyReset": result.historyReset,
                    "knownInputDiscontinuities": discontinuities(source, previous),
                    "specificResetOrCutCause": "unavailable", "views": views,
                    "completedStageWallSeconds": ["proxy": result.timings.proxySeconds,
                        "motion": result.timings.motionSeconds, "inference": result.timings.inferenceSeconds,
                        "reconstruction": result.timings.reconstructionSeconds],
                    "mlxBytes": ["active": memory.activeBytes, "cache": memory.cacheBytes, "peakActive": memory.peakActiveBytes]]
                try writeJSON(record, staging.appendingPathComponent("frame.json"))
                try FileManager.default.moveItem(at: staging, to: output.appendingPathComponent(stem))
                records.append(record)
                try publish()
                print("reference frame=\(ordinal + 1)/\(count) source=\(source.sourceFrameIndex) pts=\(source.pts.value)/\(source.pts.timescale) reset=\(result.historyReset)")
            }
            await processor.reset()
            guard try modelInventory(model) == modelFiles,
                  try Data(contentsOf: input.url) == input.data else { throw Failure("Input manifest or model changed during capture") }
            report["complete"] = true
            try publish()
        } catch {
            report["failure"] = error.localizedDescription
            try? publish()
            throw error
        }
    }

    static func preflight(_ path: URL) throws -> Input {
        let url = path.standardizedFileURL.resolvingSymlinksInPath()
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 1024 * 1024 else { throw Failure("Manifest must be1...1048576 bytes") }
        let data = try Data(contentsOf: url)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let provenance = object["provenance"] as? [String: Any],
              manifest.schemaVersion == 1, manifest.layout == layout,
              manifest.primaries == "BT.2020", manifest.transfer == "linear", manifest.units == "cd/m2",
              manifest.width > 0, manifest.height > 0,
              manifest.height <= 16384, manifest.width <= 16384,
              manifest.width <= 2_073_600 / manifest.height,
              (1...120).contains(manifest.frames.count) else { throw Failure("Unsupported raw sequence contract or bounds") }
        let frameBytes = manifest.width * manifest.height * 12
        guard UInt64(frameBytes) * UInt64(manifest.frames.count) * 4 + 4 * 1024 * 1024 <= maximumBytes else {
            throw Failure("Complete input sequence exceeds the2GiB four-view output bound")
        }
        var paths = [URL]()
        for (index, frame) in manifest.frames.enumerated() {
            guard frame.sourceFrameIndex < UInt64(Int.max), frame.pts.timescale > 0,
                  frame.duration.timescale > 0, frame.duration.value > 0,
                  frame.pts.cm.isNumeric, frame.duration.cm.isNumeric else { throw Failure("Invalid exact source timing/index") }
            if index > 0 {
                let previous = manifest.frames[index - 1]
                guard frame.sourceFrameIndex > previous.sourceFrameIndex,
                      CMTimeCompare(frame.pts.cm, previous.pts.cm) > 0 else { throw Failure("Source indices/PTS must increase strictly") }
            }
            let resolved = try contained(frame.path, in: url.deletingLastPathComponent())
            _ = try payload(resolved, frame.sha256, frameBytes)
            paths.append(resolved)
        }
        return Input(url: url, data: data, manifest: manifest, provenance: provenance, paths: paths, frameBytes: frameBytes)
    }

    static func contained(_ relative: String, in directory: URL) throws -> URL {
        guard !relative.isEmpty, !(relative as NSString).isAbsolutePath else { throw Failure("Frame path must be relative") }
        let base = directory.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(relative).standardizedFileURL.resolvingSymlinksInPath()
        guard url.pathComponents.count > base.pathComponents.count,
              Array(url.pathComponents.prefix(base.pathComponents.count)) == base.pathComponents,
              try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw Failure("Frame path escapes the sequence directory or is not a regular file")
        }
        return url
    }

    static func payload(_ path: URL, _ expectedHash: String, _ expectedBytes: Int) throws -> Data {
        guard expectedHash.count == 64, expectedHash.allSatisfy({ $0.isHexDigit && $0.isASCII }),
              try path.resourceValues(forKeys: [.fileSizeKey]).fileSize == expectedBytes else { throw Failure("Invalid float payload length/hash") }
        let data = try Data(contentsOf: path)
        guard digest(data) == expectedHash.lowercased() else { throw Failure("Float payload SHA256 mismatch: \(path.lastPathComponent)") }
        _ = try floatStatistics(data, expectedBytes: expectedBytes)
        return data
    }

    static func floatStatistics(_ data: Data, expectedBytes: Int) throws -> [String: Any] {
        guard data.count == expectedBytes, data.count % 12 == 0 else { throw Failure("Invalid RGB32F byte count") }
        var minimum = [Float](repeating: .infinity, count: 3)
        var maximum = [Float](repeating: -.infinity, count: 3)
        var negative = 0, above10000 = 0
        try data.withUnsafeBytes { bytes in
            for index in 0..<(data.count / 4) {
                let value = Float(bitPattern: UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)))
                guard value.isFinite else { throw Failure("Nonfinite source/output RGB component") }
                minimum[index % 3] = min(minimum[index % 3], value)
                maximum[index % 3] = max(maximum[index % 3], value)
                negative += value < 0 ? 1 : 0; above10000 += value > 10000 ? 1 : 0
            }
        }
        return ["minimumRGB": minimum, "maximumRGB": maximum, "negativeComponents": negative,
                "above10000Components": above10000, "nonfiniteComponents": 0]
    }

    static func discontinuities(_ current: InputFrame, _ previous: InputFrame?) -> [String] {
        guard let previous else { return ["cold-start"] }
        var reasons = [String]()
        if current.sourceFrameIndex != previous.sourceFrameIndex + 1 { reasons.append("source-frame-index-gap") }
        let gap = (current.pts.cm - (previous.pts.cm + previous.duration.cm)).seconds
        if abs(gap) > max(0.001, previous.duration.cm.seconds * 0.5) { reasons.append("PTS-duration-gap-exceeds-processor-threshold") }
        return reasons
    }

    static func modelInventory(_ url: URL) throws -> [String: String] {
        let manager = FileManager.default
        guard let enumerator = manager.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                  options: []) else { throw Failure("Model package must be a readable directory") }
        var result = [String: String](), total: UInt64 = 0
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            guard result.count < 128 else { throw Failure("Model package file count exceeds128") }
            let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size >= 0, UInt64(size) <= 1024 * 1024 * 1024 - total else { throw Failure("Model package exceeds1GiB") }
            total += UInt64(size)
            result[String(file.path.dropFirst(url.path.count + 1))] = try fileDigest(file)
        }
        guard result["weights.safetensors"] != nil else { throw Failure("Model package has no weights.safetensors") }
        return result
    }

    static func runtimeProvenance() -> [String: Any] {
        let binary = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath()
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        var result: [String: Any] = ["binary": binary.path, "binarySHA256": (try? fileDigest(binary)) ?? "unavailable",
                                    "os": ProcessInfo.processInfo.operatingSystemVersionString, "arguments": CommandLine.arguments]
        for (key, relative) in [("rootRevision", "."), ("mlxDLSSRevision", "vendor/MLX-DLSS"),
                                ("mpvRevision", "vendor/mpv")] {
            result[key] = command(["-C", cwd.appendingPathComponent(relative).path, "rev-parse", "HEAD"])
        }
        result["rootStatus"] = command(["status", "--porcelain"])
        result["diffSHA256"] = digest(Data(command(["diff", "--binary"]).utf8))
        var sources = [String: String]()
        for path in ["tools/FrameBenchmark/FrameReferenceSequence.swift", "tools/FrameBenchmark/FrameBenchmarkCommand.swift",
                     "vendor/MLX-DLSS/Sources/DLSSMedia/NativeHDRProcessor.swift",
                     "vendor/MLX-DLSS/Sources/DLSSMedia/NativeOpticalFlow.swift",
                     "vendor/MLX-DLSS/Sources/DLSSMLX/MLXNeuralRenderingDisplayCodec.swift"] {
            sources[path] = (try? fileDigest(cwd.appendingPathComponent(path))) ?? "unavailable"
        }
        result["sourceSHA256"] = sources
        return result
    }
    static func command(_ args: [String]) -> String {
        let process = Process(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return "unavailable" }
        let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return process.terminationStatus == 0 ? String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .newlines) : "unavailable"
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func fileDigest(_ path: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: path)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1024 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func seconds(_ start: ContinuousClock.Instant) -> Double {
        let value = start.duration(to: .now).components
        return Double(value.seconds) + Double(value.attoseconds) / 1e18
    }
    static func writeJSON(_ value: [String: Any], _ url: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        guard data.count <= 1024 * 1024 else { throw Failure("Diagnostic metadata exceeds1MiB") }
        try data.write(to: url, options: .atomic)
    }

    /// Pure CPU format/integrity checks; never constructs an MLX frame/model.
    static func selfTest() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("reference-input-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        var checks = 0
        func reject(_ operation: () throws -> Void) throws {
            do { try operation() } catch { checks += 1; return }
            throw Failure("CPU self-test accepted invalid input")
        }
        let floats: [Float] = [-0.5, 203, 10001]
        let data = floats.withUnsafeBytes { Data($0) }
        let file = root.appendingPathComponent("frame.rgb32f")
        try data.write(to: file)
        let metadata: [String: Any] = ["schemaVersion": 1, "width": 1, "height": 1, "layout": layout,
            "primaries": "BT.2020", "transfer": "linear", "units": "cd/m2", "provenance": ["test": true],
            "frames": [["sourceFrameIndex": 10000, "path": "frame.rgb32f", "sha256": digest(data),
                        "pts": ["value": 0, "timescale": 2997], "duration": ["value": 125, "timescale": 2997]]]]
        let manifest = root.appendingPathComponent("input.json")
        try writeJSON(metadata, manifest)
        let input = try preflight(manifest)
        guard try payload(file, digest(data), 12) == data, input.frameBytes == 12 else { throw Failure("Valid data changed") }
        checks += 1
        try reject { _ = try payload(file, String(repeating: "0", count: 64), 12) }
        try reject { _ = try payload(file, digest(data), 24) }
        try reject { _ = try contained("../outside.rgb32f", in: root) }
        try reject { _ = try contained(file.path, in: root) }
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside-\(UUID()).rgb32f")
        try data.write(to: outside)
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: outside)
        try reject { _ = try contained("escape", in: root) }
        let nonfinite: [Float] = [1, .nan, 2]
        try reject { _ = try floatStatistics(nonfinite.withUnsafeBytes { Data($0) }, expectedBytes: 12) }
        var duplicate = metadata
        let frame = (metadata["frames"] as! [[String: Any]])[0]
        duplicate["frames"] = [frame, frame]
        try writeJSON(duplicate, manifest)
        try reject { _ = try preflight(manifest) }
        var invalid = frame; invalid["duration"] = ["value": 0, "timescale": 2997]
        duplicate["frames"] = [invalid]; try writeJSON(duplicate, manifest)
        try reject { _ = try preflight(manifest) }
        let largePTS: Int64 = 9_000_000_000_000_000_000
        let previous = InputFrame(sourceFrameIndex: 10, path: "unused", sha256: "unused",
                                  pts: Time(value: largePTS, timescale: 1), duration: Time(value: 1, timescale: 1))
        let current = InputFrame(sourceFrameIndex: 11, path: "unused", sha256: "unused",
                                 pts: Time(value: largePTS + 1, timescale: 1), duration: Time(value: 1, timescale: 1))
        guard discontinuities(current, previous).isEmpty else { throw Failure("Exact large PTS incorrectly labeled discontinuous") }
        checks += 1
        print("reference-sequence CPU checks passed=\(checks); no model or GPU work")
    }
}
