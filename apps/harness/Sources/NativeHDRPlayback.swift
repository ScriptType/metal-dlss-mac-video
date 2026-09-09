import CoreVideo
import DLSSMedia
import DLSSMLX
import Foundation
import FrameEngine
import Metal

struct HDRHarnessOptions: Sendable {
    var mediaURL: URL?
    var captureDirectory: URL?
    var reportURL: URL?
    var frameLimit: Int?
    var headless = false
    var exitAfterPlayback = false
    var captureEvery = 30
    var headroom: Double = 4

    init(arguments: [String]) throws {
        var i = 0
        while i < arguments.count {
            let argument = arguments[i]
            func value() throws -> String {
                i += 1
                guard i < arguments.count else { throw MLXMediaError("Missing value for \(argument)") }
                return arguments[i]
            }
            switch argument {
            case "--capture-dir": captureDirectory = URL(fileURLWithPath: try value(), isDirectory: true)
            case "--report": reportURL = URL(fileURLWithPath: try value())
            case "--frames":
                guard let count = Int(try value()), count > 0 else { throw MLXMediaError("--frames must be positive") }
                frameLimit = count
            case "--capture-every":
                guard let count = Int(try value()), count > 0 else { throw MLXMediaError("--capture-every must be positive") }
                captureEvery = count
            case "--headroom":
                guard let level = Double(try value()), level.isFinite, level >= 1 else { throw MLXMediaError("--headroom must be at least 1") }
                headroom = level
            case "--headless": headless = true
            case "--exit-after-playback": exitAfterPlayback = true
            default:
                guard !argument.hasPrefix("-"), mediaURL == nil else { throw MLXMediaError("Unknown argument: \(argument)") }
                mediaURL = URL(fileURLWithPath: argument)
            }
            i += 1
        }
        if headless { exitAfterPlayback = true }
        if headless && mediaURL == nil { throw MLXMediaError("--headless requires a media path") }
    }
}

struct HDRHarnessReport: Codable, Sendable {
    let source: String
    let mode: String
    let decodedFrames: Int
    let completedFrames: Int
    let sourceDimensions: [Int]
    let presentationDimensions: [Int]
    let firstPTSSeconds: Double?
    let lastPTSSeconds: Double?
    let completedGPUSeconds: Double
    let elapsedSeconds: Double
    let captures: [String]
    let display: HDRDisplayConfiguration
    let machine: String
    let os: String
    let evidence: String
    let audio: String
}

/// One decoded frame and one presentation submission at a time. This diagnostic
/// controller exercises import/packing/native display while selected-core audio,
/// seeking and temporal scheduling are implemented independently.
@MainActor
final class NativeHDRPlayback {
    private var task: Task<Void, Never>?
    private var generation: UInt64 = 0
    private var paused = false
    var onStatus: ((String) -> Void)?
    var onFinish: ((Result<HDRHarnessReport, any Error>) -> Void)?
    private let surface: HDRMetalView
    private let options: HDRHarnessOptions
    private var textureCache: CVMetalTextureCache

    init(surface: HDRMetalView, options: HDRHarnessOptions) throws {
        self.surface = surface; self.options = options
        var cache: CVMetalTextureCache?
        let status = CVMetalTextureCacheCreate(nil, nil, surface.renderer.device, nil, &cache)
        guard status == kCVReturnSuccess, let cache else { throw MLXMediaError("Cannot create display texture cache: \(status)") }
        textureCache = cache
    }

    func load(_ url: URL) {
        task?.cancel(); generation &+= 1; paused = false; surface.clear()
        let currentGeneration = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await run(url: url, generation: currentGeneration)
                guard generation == currentGeneration, !Task.isCancelled else { return }
                onFinish?(.success(result))
            } catch {
                guard generation == currentGeneration, !Task.isCancelled else { return }
                onFinish?(.failure(error))
            }
        }
    }

    func play() { paused = false; onStatus?("Playing · original HDR · video harness") }
    func pause() { paused = true; onStatus?("Paused · original HDR") }
    func stop() { task?.cancel(); generation &+= 1; surface.clear() }

    private func run(url: URL, generation: UInt64) async throws -> HDRHarnessReport {
        onStatus?("Importing HDR original…")
        let reader = try await NativeHDRVideoReader(url: url, sourceID: url.standardizedFileURL.path,
                                                    generation: generation)
        var writer: MLXPixelBufferWriter?
        var decoded = 0, completed = 0, gpuSeconds: Double = 0
        var firstPTS: Double?, lastPTS: Double?, epoch: Double?
        var sourceDimensions = [Int](), presentationDimensions = [Int](), captures = [String]()
        let started = ProcessInfo.processInfo.systemUptime
        while let imported = try await reader.next() {
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            let metadata = imported.metadata
            let original = imported.original
            if writer == nil { writer = try MLXPixelBufferWriter(width: original.width, height: original.height, halfOutput: true) }
            let packed = try await writer!.write(original)
            try Task.checkCancellation()
            let frame = try surfaceFrame(imported, packed: packed)
            sourceDimensions = [frame.texture.width, frame.texture.height]
            decoded += 1
            let pts = metadata.time.seconds
            if firstPTS == nil { firstPTS = pts }
            if epoch == nil { epoch = ProcessInfo.processInfo.systemUptime - pts }
            // The video-only harness does not discard a late frame: all captured
            // originals keep their exact source PTS. Decode and GPU waits suspend.
            if !options.headless {
                while true {
                    if paused {
                        let pauseStart = ProcessInfo.processInfo.systemUptime
                        try await Task.sleep(for: .milliseconds(20))
                        epoch! += ProcessInfo.processInfo.systemUptime - pauseStart
                    } else if ProcessInfo.processInfo.systemUptime < epoch! + pts {
                        try await Task.sleep(for: .milliseconds(2))
                    } else { break }
                }
            }
            let capture = options.captureDirectory != nil && (decoded - 1) % options.captureEvery == 0
            let result: HDRPresentationCompletion
            if options.headless {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
                    width: frame.texture.width, height: frame.texture.height, mipmapped: false)
                descriptor.usage = [.renderTarget, .shaderRead]; descriptor.storageMode = .private
                guard let target = surface.renderer.device.makeTexture(descriptor: descriptor) else { throw MLXMediaError("Cannot allocate offscreen target") }
                let display = HDRDisplayConfiguration(currentHeadroom: options.headroom, potentialHeadroom: options.headroom)
                result = try await withCheckedThrowingContinuation { continuation in
                    do {
                        try surface.renderer.render(frame, to: target, display: display,
                            captureDirectory: capture ? options.captureDirectory : nil) { result in
                            if let error = result.error { continuation.resume(throwing: MLXMediaError(error)) }
                            else { continuation.resume(returning: result) }
                        }
                    } catch { continuation.resume(throwing: error) }
                }
                presentationDimensions = [target.width, target.height]
            } else {
                result = try await surface.presentAndWait(frame, capture: capture)
                let scale = surface.window?.backingScaleFactor ?? 1
                presentationDimensions = [Int(surface.bounds.width * scale), Int(surface.bounds.height * scale)]
            }
            completed += 1; gpuSeconds += result.gpuSeconds; lastPTS = pts
            if let captureURL = result.captureURL { captures.append(captureURL.path) }
            onStatus?(String(format: "Original HDR · %.3f s · frame %d · %.1f× EDR · video harness", pts, completed,
                             options.headless ? options.headroom : surface.displayConfiguration.currentHeadroom))
            if let limit = options.frameLimit, completed >= limit { await reader.cancel(); break }
        }
        let report = HDRHarnessReport(source: url.path, mode: "retained original bypass", decodedFrames: decoded,
            completedFrames: completed, sourceDimensions: sourceDimensions, presentationDimensions: presentationDimensions,
            firstPTSSeconds: firstPTS, lastPTSSeconds: lastPTS, completedGPUSeconds: gpuSeconds,
            elapsedSeconds: ProcessInfo.processInfo.systemUptime - started, captures: captures,
            display: options.headless ? HDRDisplayConfiguration(currentHeadroom: options.headroom, potentialHeadroom: options.headroom) : surface.displayConfiguration,
            machine: surface.renderer.device.name, os: ProcessInfo.processInfo.operatingSystemVersionString,
            evidence: options.headless ? "offscreen completed GPU captures; no physical display validation" :
                "native drawable submission and completed GPU work; physical colour accuracy requires observed/calibrated display validation",
            audio: "video-only development harness; selected-core synchronization is separate")
        if let reportURL = options.reportURL {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: reportURL, options: .atomic)
        }
        return report
    }

    private func surfaceFrame(_ frame: MLXHDRFrame, packed: MLXPixelBuffer) throws -> HDRSurfaceFrame {
        var view: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, packed.buffer, nil,
            .rgba16Float, packed.width, packed.height, 0, &view)
        guard status == kCVReturnSuccess, let view, let texture = CVMetalTextureGetTexture(view) else {
            throw MLXMediaError("Cannot bind packed HDR texture: \(status)")
        }
        let metadata = frame.metadata
        let owner = HDRPackedOwner(original: frame, packed: packed, view: view)
        var sourceColor = metadata.color.sourceTags
        sourceColor["interpretedTransfer"] = String(describing: metadata.color.transfer)
        sourceColor["interpretedPrimaries"] = String(describing: metadata.color.primaries)
        sourceColor["interpretedMatrix"] = String(describing: metadata.color.matrix)
        sourceColor["range"] = metadata.color.fullRange ? "full" : "video"
        sourceColor["chromaLocation"] = String(describing: metadata.color.chromaLocation)
        sourceColor["hlgPeakNits"] = String(metadata.color.hlgPeakNits)
        sourceColor["assumptions"] = metadata.color.assumptions.joined(separator: "; ")
        sourceColor["masteringDisplayBase64"] = metadata.color.masteringDisplay?.base64EncodedString()
        sourceColor["contentLightLevelBase64"] = metadata.color.contentLightLevel?.base64EncodedString()
        return HDRSurfaceFrame(texture: texture, owner: owner, time: metadata.time, duration: metadata.duration,
            sourceID: metadata.sourceID, frameIndex: Int(metadata.frameIndex), generation: metadata.generation,
            crop: metadata.crop, transform: metadata.transform, pixelAspectRatio: metadata.pixelAspectRatio,
            referenceWhiteNits: metadata.color.referenceWhiteNits, sourceColor: sourceColor)
    }
}

private final class HDRPackedOwner: @unchecked Sendable {
    let original: MLXHDRFrame
    let packed: MLXPixelBuffer
    let view: CVMetalTexture
    init(original: MLXHDRFrame, packed: MLXPixelBuffer, view: CVMetalTexture) {
        self.original = original; self.packed = packed; self.view = view
    }
}
