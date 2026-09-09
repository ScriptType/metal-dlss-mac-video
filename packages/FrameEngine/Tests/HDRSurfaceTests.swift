import CoreMedia
import Foundation
import FrameEngine
import Metal
import Testing

private func surfaceTexture(_ device: any MTLDevice, width: Int, height: Int, rgb: [[Float]]? = nil) throws -> any MTLTexture {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: width, height: height, mipmapped: false)
    descriptor.usage = [.shaderRead, .renderTarget]; descriptor.storageMode = .shared
    let texture = try #require(device.makeTexture(descriptor: descriptor))
    if let rgb {
        let half = rgb.flatMap { ($0 + [1]).map { Float16($0).bitPattern } }
        half.withUnsafeBytes { texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                                               withBytes: $0.baseAddress!, bytesPerRow: width * 8) }
    }
    return texture
}

private func readSurface(_ texture: any MTLTexture) -> [Float] {
    var bits = [UInt16](repeating: 0, count: texture.width * texture.height * 4)
    bits.withUnsafeMutableBytes { texture.getBytes($0.baseAddress!, bytesPerRow: texture.width * 8,
                                                  from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0) }
    return bits.map { Float(Float16(bitPattern: $0)) }
}

private func drawSurface(_ renderer: HDRDisplayRenderer, frame: HDRSurfaceFrame, target: any MTLTexture,
                         capture: URL? = nil) async throws -> HDRPresentationCompletion {
    try await withCheckedThrowingContinuation { continuation in
        do {
            try renderer.render(frame, to: target, display: HDRDisplayConfiguration(currentHeadroom: 4),
                                captureDirectory: capture) { result in continuation.resume(returning: result) }
        } catch { continuation.resume(throwing: error) }
    }
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func retainedHDRSurfacePreservesOriginalAndMapsHeadroom() async throws {
    let renderer = try HDRDisplayRenderer()
    let input = [[Float](repeating: 0.01, count: 3), [203,203,203], [1000,1000,1000], [10000,10000,10000], [203,0,0]]
    let source = try surfaceTexture(renderer.device, width: 5, height: 1, rgb: input)
    let target = try surfaceTexture(renderer.device, width: 5, height: 1)
    let frame = HDRSurfaceFrame(texture: source, owner: NSObject(), time: CMTime(value: 1001, timescale: 24000),
                                duration: CMTime(value: 1001, timescale: 24000), sourceID: "numeric-fixture", frameIndex: 7, generation: 2)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let before = readSurface(source)
    let result = try await drawSurface(renderer, frame: frame, target: target, capture: directory)
    #expect(result.error == nil)
    #expect(readSurface(source) == before)
    let output = readSurface(target)
    #expect(abs(output[0] - 0.01 / 203) < 0.000001)
    #expect(abs(output[4] - 1) < 0.001)
    #expect(output[8] > 1 && output[8] < 4)
    #expect(output[12] > output[8] && output[12] <= 4)
    // A BT.2020 red requires negative P3 green. It must not be clipped into
    // the SDR proxy gamut before the layer's colour-managed interpretation.
    #expect(output[17] < 0)
    let recordURL = try #require(result.captureURL)
    let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: recordURL)) as? [String: Any])
    let buffers = try #require(record["buffers"] as? [[String: Any]])
    #expect((buffers[0]["maxRGB"] as? [Double]) == [10000,10000,10000])
    #expect((buffers[0]["units"] as? String) == "cd/m2")
    #expect((record["pts"] as? [String: Int]) == ["value": 1001, "timescale": 24000])
}

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func hdrSurfaceAppliesCropAndRotationBeforeAspectFit() async throws {
    let renderer = try HDRDisplayRenderer()
    let input: [[Float]] = [1,2,10,20,3,4,30,40].map { [Float](repeating: Float($0), count: 3) }
    let source = try surfaceTexture(renderer.device, width: 4, height: 2, rgb: input)
    let target = try surfaceTexture(renderer.device, width: 2, height: 2)
    let frame = HDRSurfaceFrame(texture: source, owner: NSObject(), time: .zero, duration: CMTime(value: 1, timescale: 30),
        sourceID: "geometry-fixture", frameIndex: 0, generation: 0,
        crop: CGRect(x: 2, y: 0, width: 2, height: 2),
        transform: CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 2, ty: 0))
    let result = try await drawSurface(renderer, frame: frame, target: target)
    #expect(result.error == nil)
    let output = readSurface(target)
    for (pixel, nits) in [Float(30),10,40,20].enumerated() {
        #expect(abs(output[pixel * 4] * 203 - nits) < 0.04)
    }
}
