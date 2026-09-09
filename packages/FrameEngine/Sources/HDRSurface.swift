import AppKit
import CoreMedia
import Metal
import QuartzCore
import simd

/// The presentation boundary accepts retained, linear BT.2020 RGBA16F pixels in
/// absolute nits. The original bypass binds this texture directly, never a proxy.
public struct HDRSurfaceFrame: @unchecked Sendable {
    public let texture: any MTLTexture
    public let owner: AnyObject
    public let time: CMTime
    public let duration: CMTime
    public let sourceID: String
    public let frameIndex: Int
    public let generation: UInt64
    public let crop: CGRect
    public let transform: CGAffineTransform
    public let pixelAspectRatio: Double
    public let referenceWhiteNits: Float
    public let sourceColor: [String: String]
    public let readinessEvent: (any MTLSharedEvent)?
    public let readinessValue: UInt64

    public init(texture: any MTLTexture, owner: AnyObject, time: CMTime, duration: CMTime,
                sourceID: String, frameIndex: Int, generation: UInt64,
                crop: CGRect? = nil, transform: CGAffineTransform = .identity,
                pixelAspectRatio: Double = 1, referenceWhiteNits: Float = 203,
                sourceColor: [String: String] = [:],
                readinessEvent: (any MTLSharedEvent)? = nil, readinessValue: UInt64 = 0) {
        self.texture = texture; self.owner = owner; self.time = time; self.duration = duration
        self.sourceID = sourceID; self.frameIndex = frameIndex; self.generation = generation
        self.crop = crop ?? CGRect(x: 0, y: 0, width: texture.width, height: texture.height)
        self.transform = transform; self.pixelAspectRatio = pixelAspectRatio
        self.referenceWhiteNits = referenceWhiteNits; self.sourceColor = sourceColor
        self.readinessEvent = readinessEvent; self.readinessValue = readinessValue
    }
}

public struct HDRDisplayConfiguration: Codable, Sendable {
    public var screenName: String
    public var currentHeadroom: Double
    public var potentialHeadroom: Double
    public var referenceHeadroom: Double
    public var colorSpace = "extended-linear Display P3 (D65)"
    public var pixelFormat = "RGBA16Float"
    public var edrEnabled = true
    public var toneMapping = "chromaticity-preserving RGB-maximum exponential shoulder; knee=min(1,0.75*headroom)"

    public init(screenName: String = "offscreen", currentHeadroom: Double = 1,
                potentialHeadroom: Double = 1, referenceHeadroom: Double = 1) {
        self.screenName = screenName; self.currentHeadroom = currentHeadroom
        self.potentialHeadroom = potentialHeadroom; self.referenceHeadroom = referenceHeadroom
    }

    @MainActor public init(screen: NSScreen?) {
        self.init(screenName: screen?.localizedName ?? "unavailable",
                  currentHeadroom: Double(screen?.maximumExtendedDynamicRangeColorComponentValue ?? 1),
                  potentialHeadroom: Double(screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1),
                  referenceHeadroom: Double(screen?.maximumReferenceExtendedDynamicRangeColorComponentValue ?? 1))
    }
}

public struct HDRPresentationCompletion: Sendable {
    public let frameIndex: Int
    public let generation: UInt64
    public let gpuSeconds: Double
    public let captureURL: URL?
    public let error: String?
}

/// Thread-safe immutable pipelines. All texture/decoder owners are held through
/// command completion. A capture deliberately adds a GPU readback; normal display
/// uses no readback or CPU wait. The caller controls admission and generations.
public final class HDRDisplayRenderer: @unchecked Sendable {
    public let device: any MTLDevice
    private let queue: any MTLCommandQueue
    private let pipeline: any MTLRenderPipelineState

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else {
            throw ProbeError.unavailable("Metal HDR presentation unavailable")
        }
        self.device = device; self.queue = queue
        let library = try device.makeLibrary(source: Self.shader, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "hdr_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "hdr_fragment")
        descriptor.colorAttachments[0].pixelFormat = .rgba16Float
        pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
    }

    @discardableResult
    public func render(_ frame: HDRSurfaceFrame, to target: any MTLTexture,
                       display: HDRDisplayConfiguration, drawable: (any CAMetalDrawable)? = nil,
                       captureDirectory: URL? = nil,
                       completion: @escaping @Sendable (HDRPresentationCompletion) -> Void) throws -> any MTLCommandBuffer {
        guard frame.texture.pixelFormat == .rgba16Float, target.pixelFormat == .rgba16Float,
              frame.referenceWhiteNits.isFinite, frame.referenceWhiteNits > 0,
              frame.pixelAspectRatio.isFinite, frame.pixelAspectRatio > 0,
              display.currentHeadroom.isFinite, display.currentHeadroom >= 1,
              frame.texture.device.registryID == device.registryID,
              target.device.registryID == device.registryID else {
            throw ProbeError.unavailable("HDR surface requires RGBA16F nits, positive reference white/aspect, and one Metal device")
        }
        guard let command = queue.makeCommandBuffer() else { throw ProbeError.unavailable("HDR command allocation failed") }
        command.label = "HDR display frame \(frame.frameIndex) generation \(frame.generation)"
        if let event = frame.readinessEvent { command.encodeWaitForEvent(event, value: frame.readinessValue) }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            throw ProbeError.unavailable("HDR render encoder allocation failed")
        }
        let vertices = try Self.vertices(frame: frame, width: target.width, height: target.height)
        var parameters = SIMD4<Float>(frame.referenceWhiteNits, Float(display.currentHeadroom), 0, 0)
        encoder.setRenderPipelineState(pipeline)
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setFragmentBytes(&parameters, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentTexture(frame.texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        let capture = try captureDirectory.map { directory in
            try HDRSurfaceCapture(command: command, device: device, frame: frame, target: target,
                                  display: display, directory: directory)
        }
        if let drawable { command.present(drawable) }
        command.addCompletedHandler { [frame, capture] completed in
            // Keep the retained source, CVMetalTexture and optional upstream event
            // alive until the last display/capture access has finished.
            withExtendedLifetime(frame.owner) {}
            var failure = completed.error?.localizedDescription
            var captureURL: URL?
            if failure == nil, let capture {
                do { captureURL = try capture.save() } catch { failure = error.localizedDescription }
            }
            completion(HDRPresentationCompletion(frameIndex: frame.frameIndex, generation: frame.generation,
                gpuSeconds: max(0, completed.gpuEndTime - completed.gpuStartTime),
                captureURL: captureURL, error: failure))
        }
        command.commit()
        return command
    }

    private static func vertices(frame: HDRSurfaceFrame, width: Int, height: Int) throws -> [SIMD4<Float>] {
        let bounds = CGRect(x: 0, y: 0, width: frame.texture.width, height: frame.texture.height)
        let crop = frame.crop.intersection(bounds)
        guard !crop.isNull, !crop.isEmpty else { throw ProbeError.unavailable("Invalid HDR frame crop") }
        let source = [CGPoint(x: crop.minX, y: crop.minY), CGPoint(x: crop.maxX, y: crop.minY),
                      CGPoint(x: crop.minX, y: crop.maxY), CGPoint(x: crop.maxX, y: crop.maxY)]
        // Pixel aspect is applied in source coordinates before rotation.
        let transformed = source.map {
            CGPoint(x: $0.x * frame.pixelAspectRatio, y: $0.y).applying(frame.transform)
        }
        let minX = transformed.map(\.x).min()!, maxX = transformed.map(\.x).max()!
        let minY = transformed.map(\.y).min()!, maxY = transformed.map(\.y).max()!
        guard maxX > minX, maxY > minY, [minX, minY, maxX, maxY].allSatisfy(\.isFinite) else {
            throw ProbeError.unavailable("Invalid HDR frame transform")
        }
        let scale = min(Double(width) / (maxX - minX), Double(height) / (maxY - minY))
        return zip(source, transformed).map { uv, p in
            SIMD4(Float((p.x - (minX + maxX) / 2) * scale * 2 / Double(width)),
                  Float(-(p.y - (minY + maxY) / 2) * scale * 2 / Double(height)),
                  Float(uv.x / Double(frame.texture.width)), Float(uv.y / Double(frame.texture.height)))
        }
    }

    private static let shader = """
    #include <metal_stdlib>
    using namespace metal;
    struct Vertex { float4 position [[position]]; float2 uv; };
    vertex Vertex hdr_vertex(uint id [[vertex_id]], constant float4 *vertices [[buffer(0)]]) {
        Vertex v; v.position=float4(vertices[id].xy,0,1); v.uv=vertices[id].zw; return v;
    }
    fragment half4 hdr_fragment(Vertex v [[stage_in]], texture2d<half> original [[texture(0)]],
                               constant float4 &parameters [[buffer(0)]]) {
        constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear);
        float3 bt2020=float3(original.sample(s,v.uv).rgb)/parameters.x;
        // BT.2020 D65 -> Display P3 D65. Keep negative wide-gamut components;
        // ColorSync interprets extended-linear P3 at the layer boundary.
        float3 p3=float3(dot(bt2020,float3(1.3435783,-0.2821797,-0.0613986)),
                        dot(bt2020,float3(-0.0652975,1.0757879,-0.0104905)),
                        dot(bt2020,float3(0.0028218,-0.0195985,1.0167767)));
        float headroom=max(1.0f,parameters.y), knee=min(1.0f,0.75f*headroom);
        float peak=max(p3.r,max(p3.g,p3.b));
        if (peak>knee) {
            float span=headroom-knee;
            float mapped=knee+span*(1.0f-exp(-(peak-knee)/span));
            p3*=mapped/peak;
        }
        return half4(half3(p3),1.0h);
    }
    """
}

private final class HDRSurfaceCapture: @unchecked Sendable {
    private let source: any MTLBuffer
    private let mapped: any MTLBuffer
    private let sourceStride: Int
    private let mappedStride: Int
    private let frame: HDRSurfaceFrame
    private let width: Int
    private let height: Int
    private let display: HDRDisplayConfiguration
    private let directory: URL

    init(command: any MTLCommandBuffer, device: any MTLDevice, frame: HDRSurfaceFrame,
         target: any MTLTexture, display: HDRDisplayConfiguration, directory: URL) throws {
        sourceStride = (frame.texture.width * 8 + 255) / 256 * 256
        mappedStride = (target.width * 8 + 255) / 256 * 256
        guard let source = device.makeBuffer(length: sourceStride * frame.texture.height, options: .storageModeShared),
              let mapped = device.makeBuffer(length: mappedStride * target.height, options: .storageModeShared),
              let encoder = command.makeBlitCommandEncoder() else { throw ProbeError.unavailable("HDR capture allocation failed") }
        self.source = source; self.mapped = mapped; self.frame = frame
        self.width = target.width; self.height = target.height; self.display = display; self.directory = directory
        encoder.copy(from: frame.texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                     sourceSize: MTLSize(width: frame.texture.width, height: frame.texture.height, depth: 1),
                     to: source, destinationOffset: 0, destinationBytesPerRow: sourceStride,
                     destinationBytesPerImage: sourceStride * frame.texture.height)
        encoder.copy(from: target, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                     sourceSize: MTLSize(width: target.width, height: target.height, depth: 1),
                     to: mapped, destinationOffset: 0, destinationBytesPerRow: mappedStride,
                     destinationBytesPerImage: mappedStride * target.height)
        encoder.endEncoding()
    }

    func save() throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stem = "g\(frame.generation)-f\(frame.frameIndex)-pts\(frame.time.value)_\(frame.time.timescale)"
        var records = [[String: Any]]()
        for (name, buffer, stride, w, h, units, primaries) in [
            ("original", source, sourceStride, frame.texture.width, frame.texture.height, "cd/m2", "BT.2020"),
            ("display", mapped, mappedStride, width, height, "relative to display SDR white", "Display P3")
        ] {
            var data = Data(capacity: w * h * 8)
            var minRGB = [Float](repeating: .infinity, count: 3), maxRGB = [Float](repeating: -.infinity, count: 3)
            var aboveWhite = 0, nonFinite = 0
            var samplePixels = [[String: Any]]()
            for y in 0..<h {
                let row = buffer.contents().advanced(by: y * stride)
                data.append(row.assumingMemoryBound(to: UInt8.self), count: w * 8)
                let half = row.assumingMemoryBound(to: UInt16.self)
                for x in 0..<w {
                    var rgb = [Float]()
                    for channel in 0..<3 {
                        let value = Float(Float16(bitPattern: half[x * 4 + channel]))
                        rgb.append(value)
                        if value.isFinite { minRGB[channel] = min(minRGB[channel], value); maxRGB[channel] = max(maxRGB[channel], value) }
                        else { nonFinite += 1 }
                    }
                    if rgb.max()! > (name == "original" ? frame.referenceWhiteNits : 1) { aboveWhite += 1 }
                    if [0, w / 4, w / 2, 3 * w / 4, w - 1].contains(x), [h / 4, 3 * h / 4].contains(y) {
                        samplePixels.append(["x": x, "y": y, "rgb": rgb.map { $0.isFinite ? Double($0) : 0 }])
                    }
                }
            }
            let filename = "\(stem)-\(name).rgba16f"
            try data.write(to: directory.appendingPathComponent(filename), options: .atomic)
            records.append(["file": filename, "width": w, "height": h, "bytesPerRow": w * 8,
                            "layout": "RGBA binary16 little-endian top-to-bottom", "transfer": "linear",
                            "primaries": primaries, "units": units,
                            "minRGB": minRGB.map { $0.isFinite ? Double($0) : 0 },
                            "maxRGB": maxRGB.map { $0.isFinite ? Double($0) : 0 },
                            "pixelsAboveReferenceWhite": aboveWhite, "nonFiniteComponents": nonFinite,
                            "samples": samplePixels])
        }
        let displayData = try JSONEncoder().encode(display)
        let record: [String: Any] = ["schemaVersion": 1, "sourceID": frame.sourceID, "frameIndex": frame.frameIndex,
            "generation": frame.generation, "pts": ["value": frame.time.value, "timescale": Int64(frame.time.timescale)],
            "duration": ["value": frame.duration.value, "timescale": Int64(frame.duration.timescale)],
            "referenceWhiteNits": frame.referenceWhiteNits, "sourceColor": frame.sourceColor,
            "crop": [frame.crop.minX, frame.crop.minY, frame.crop.width, frame.crop.height],
            "transform": [frame.transform.a, frame.transform.b, frame.transform.c, frame.transform.d, frame.transform.tx, frame.transform.ty],
            "pixelAspectRatio": frame.pixelAspectRatio,
            "display": try JSONSerialization.jsonObject(with: displayData), "buffers": records,
            "boundary": "retained original -> unclipped RGBA16F nits -> display mapping; original bypass never enters neural proxy",
            "evidence": "completed GPU buffer capture; does not establish physical display accuracy"]
        let output = directory.appendingPathComponent("\(stem).json")
        try JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]).write(to: output, options: .atomic)
        return output
    }
}

@MainActor
public final class HDRMetalView: NSView {
    public let renderer: HDRDisplayRenderer
    public private(set) var currentFrame: HDRSurfaceFrame?
    public private(set) var displayConfiguration = HDRDisplayConfiguration()
    public var captureDirectory: URL?
    public var onCompletion: (@Sendable (HDRPresentationCompletion) -> Void)?
    private let slots = DispatchSemaphore(value: 3)
    private var needsCapture = false
    private var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    public init(device: (any MTLDevice)? = MTLCreateSystemDefaultDevice()) throws {
        renderer = try HDRDisplayRenderer(device: device)
        super.init(frame: .zero)
        wantsLayer = true
        let metal = CAMetalLayer()
        metal.device = renderer.device; metal.pixelFormat = .rgba16Float
        metal.colorspace = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)
        metal.wantsExtendedDynamicRangeContent = true
        metal.framebufferOnly = false // diagnostic blit capture reads rendered pixels
        metal.maximumDrawableCount = 3
        layer = metal
        setAccessibilityLabel("Native HDR video surface")
        setAccessibilityRole(.image)
    }
    required init?(coder: NSCoder) { fatalError("Use init()") }
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateDisplay() }
    public override func viewDidChangeBackingProperties() { super.viewDidChangeBackingProperties(); updateDisplay() }
    public override func layout() { super.layout(); updateDisplay() }

    public func updateDisplay() {
        displayConfiguration = HDRDisplayConfiguration(screen: window?.screen)
        let scale = window?.backingScaleFactor ?? 1
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        redraw()
    }

    public func present(_ frame: HDRSurfaceFrame, capture: Bool = false) {
        currentFrame = frame; needsCapture = capture; redraw()
    }

    /// Development harness completion boundary. Suspension yields the main actor;
    /// production adapters can use present/redraw with their own playback clock.
    public func presentAndWait(_ frame: HDRSurfaceFrame, capture: Bool = false) async throws -> HDRPresentationCompletion {
        currentFrame = frame
        displayConfiguration = HDRDisplayConfiguration(screen: window?.screen)
        guard acquireSlot() else { throw ProbeError.unavailable("HDR presentation queue full") }
        guard let drawable = metalLayer.nextDrawable() else { slots.signal(); throw ProbeError.unavailable("HDR drawable unavailable") }
        let callback = onCompletion, slots = slots
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try renderer.render(frame, to: drawable.texture, display: displayConfiguration, drawable: drawable,
                                    captureDirectory: capture ? captureDirectory : nil) { result in
                    slots.signal(); callback?(result)
                    if let error = result.error { continuation.resume(throwing: ProbeError.unavailable(error)) }
                    else { continuation.resume(returning: result) }
                }
            } catch { slots.signal(); continuation.resume(throwing: error) }
        }
    }

    public func clear() { currentFrame = nil; needsCapture = false }

    private func acquireSlot() -> Bool { slots.wait(timeout: .now()) == .success }

    public func redraw() {
        guard let frame = currentFrame, acquireSlot() else { return }
        displayConfiguration = HDRDisplayConfiguration(screen: window?.screen)
        guard let drawable = metalLayer.nextDrawable() else { slots.signal(); return }
        let completion = onCompletion, slots = slots
        do {
            try renderer.render(frame, to: drawable.texture, display: displayConfiguration, drawable: drawable,
                                captureDirectory: needsCapture ? captureDirectory : nil) { result in
                slots.signal(); completion?(result)
            }
            needsCapture = false
        } catch {
            slots.signal()
            completion?(HDRPresentationCompletion(frameIndex: frame.frameIndex, generation: frame.generation,
                                                  gpuSeconds: 0, captureURL: nil, error: error.localizedDescription))
        }
    }
}
