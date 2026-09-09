import CFrameEngine
import CoreVideo
import CryptoKit
import DLSSMedia
import Foundation
import FrameEngine
import QuartzCore

@main
struct FrameBenchmarkCommand {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("hdr-benchmark: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
    }

    static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        func option(_ name: String) -> String? {
            guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let source = option("--video"), let reportPath = option("--report") else {
            print("Usage: hdr-benchmark --video FILE --report JSON [--frames N] [--warmup N] [--model DIR] [--width N --height N] [--strength 0...1] [--revision GIT_SHA] [--reference JSON] [--power DESCRIPTION]")
            exit(64)
        }
        let limit = Int(option("--frames") ?? "120") ?? 120
        let warmup = Int(option("--warmup") ?? "3") ?? 3
        let width = Int(option("--width") ?? "320") ?? 320
        let height = Int(option("--height") ?? "192") ?? 192
        let model = option("--model").map { URL(fileURLWithPath: $0) }
        let strength = Float(option("--strength") ?? (model == nil ? "0" : "1")) ?? 0
        guard limit > warmup, warmup >= 0, limit <= 100_000, width > 0, height > 0,
              strength.isFinite, (0...1).contains(strength) else { throw FrameEngineError.invalid("Invalid benchmark settings") }
        let sourceURL = URL(fileURLWithPath: source)
        let sourceIdentity = try HDRCacheSource.fingerprint(url: sourceURL, streamIndex: 0)
        let reader = try await NativeHDRVideoReader(url: sourceURL, generation: 1)
        guard var decoded = try await reader.nextDecoded() else { throw FrameEngineError.invalid("Empty source") }
        var modelHash = "original"
        if let model {
            let data = try Data(contentsOf: model.appendingPathComponent("weights.safetensors"), options: .mappedIfSafe)
            modelHash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let configuration = MeasurementConfiguration(adapter: "native-decoder/shared-engine",
            source: "\(sourceURL.lastPathComponent);sha256=\(sourceIdentity.contentSHA256)",
            sourceWidth: decoded.pixelBuffer.width, sourceHeight: decoded.pixelBuffer.height,
            processingWidth: width, processingHeight: height, displayWidth: decoded.pixelBuffer.width,
            displayHeight: decoded.pixelBuffer.height, sourceFPS: Double(reader.nominalFrameRate),
            modelVersion: modelHash, implementationRevision: option("--revision") ?? "unrecorded",
            settingsJSON: "{\"strength\":\(strength),\"colourStrength\":1,\"referenceWhiteNits\":203,\"maximumLuminanceRatio\":2}",
            warmupFrames: warmup, displayConfiguration: "offscreen RGBA16F; no presentation",
            powerConfiguration: option("--power") ?? "unrecorded")
        let recorder = FrameMeasurementRecorder(configuration: configuration)
        let session = try FrameSession(limits: .init(slots: 3, bytes: 512 * 1024 * 1024,
            processingWidth: width, processingHeight: height),
            processor: HDRPipelineProcessor(configuration: .init(modelURL: model, modelVersion: modelHash,
                processingWidth: width, processingHeight: height, strength: strength)), measurements: recorder)
        do {
            var accepted = 0, consumed = 0
            var lastPTS: (Int64, Int32)?
            let deadline = CACurrentMediaTime() + Double(limit) * 120 + 60
            func drain() throws {
                while let output = session.poll() {
                    guard output.descriptor.generation == session.generation else { throw FrameEngineError.invalid("Obsolete output") }
                    consumed += 1
                    lastPTS = (output.descriptor.pts.value, output.descriptor.pts.timescale)
                    if consumed == 1, let reference = option("--reference") {
                        try writeReference(output, path: reference, configuration: configuration)
                    }
                }
                if session.statistics().failures > 0 { throw FrameEngineError.invalid(session.error) }
                if CACurrentMediaTime() > deadline { throw FrameEngineError.invalid("Completed-work deadline exceeded") }
            }
            while accepted < limit {
                let frame = DecoderFrameDescriptor.make(pixelBuffer: decoded.pixelBuffer.buffer,
                    metadata: decoded.metadata, sourceID: 1, generation: session.generation)
                while true {
                    let status = session.submit(frame)
                    if status == FE_ACCEPTED { accepted += 1; break }
                    guard status == FE_FULL else { throw FrameEngineError.invalid("Submission failed: \(status), \(session.error)") }
                    try drain()
                    try await Task.sleep(for: .milliseconds(1))
                }
                try drain()
                guard accepted < limit, let next = try await reader.nextDecoded() else { break }
                decoded = next
            }
            while consumed < accepted {
                try drain()
                if consumed < accepted { try await Task.sleep(for: .milliseconds(1)) }
            }
            guard accepted > warmup, consumed == accepted else { throw FrameEngineError.invalid("Insufficient completed warmed output") }
            session.close()
            await session.waitUntilIdle()
            await reader.cancel()
            try recorder.write(to: URL(fileURLWithPath: reportPath))
            let result = recorder.report()
            print("completed=\(consumed) warmed=\(result.warmedSamples) fps=\(result.completedThroughputFPS ?? 0) last_pts=\(lastPTS?.0 ?? 0)/\(lastPTS?.1 ?? 1) report=\(reportPath)")
        } catch {
            session.close()
            await session.waitUntilIdle()
            await reader.cancel()
            throw error
        }
    }

    /// Capture one completed startup frame before the warmed interval. The
    /// numeric reference is independent of display mapping and 8-bit screenshots.
    static func writeReference(_ output: CompletedFrame, path: String,
                               configuration: MeasurementConfiguration) throws {
        let buffer = output.pixelBuffer
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw FrameEngineError.invalid("Cannot read completed HDR reference")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw FrameEngineError.invalid("Missing HDR storage") }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        var samples: [[String: Any]] = []
        for y in [height / 4, height * 3 / 4] {
            let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt16.self)
            for x in [0, width / 4, width / 2, width * 3 / 4, width - 1] {
                let rgba = (0..<4).map { Float(Float16(bitPattern: row[x * 4 + $0])) }
                guard rgba.allSatisfy(\.isFinite) else { throw FrameEngineError.invalid("Nonfinite HDR reference") }
                samples.append(["x": x, "y": y, "rgba": rgba])
            }
        }
        let descriptor = output.descriptor
        let value: [String: Any] = ["schemaVersion": 1, "source": configuration.source,
            "model": configuration.modelVersion, "implementationRevision": configuration.implementationRevision,
            "width": width, "height": height, "pts": ["value": descriptor.pts.value, "timescale": Int64(descriptor.pts.timescale)],
            "primaries": "BT.2020", "transfer": "linear", "units": "cd/m2", "storage": "RGBA16F",
            "settingsJSON": configuration.settingsJSON, "samples": samples,
            "scope": "One CPU readback of the first completed startup frame; before display mapping and warmed timing"]
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
