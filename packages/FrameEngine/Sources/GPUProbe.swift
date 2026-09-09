import Foundation
import Metal

public enum ProbeError: Error {
    case unavailable(String)
    case clipped([Float])
}

public struct GPUReport: Codable, Sendable {
    public let device: String
    public let unifiedMemory: Bool
    public let physicalMemoryBytes: UInt64
    public let recommendedGPUWorkingSetBytes: UInt64
    public let rgba16FloatSamples: [Float]
}

/// Small completed GPU-work check. This tests float storage, not HDR display accuracy.
public enum GPUProbe {
    public static func run() throws -> GPUReport {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            throw ProbeError.unavailable("No Metal device or command queue")
        }
        let source = """
        #include <metal_stdlib>
        using namespace metal;
        kernel void hdr_probe(texture2d<half, access::write> output [[texture(0)]],
                              uint2 position [[thread_position_in_grid]]) {
            const half values[] = {0.0h, 0.125h, 1.0h, 4.0h, 16.0h};
            output.write(half4(values[position.x], 0.0h, 0.0h, 1.0h), position);
        }
        """
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "hdr_probe") else {
            throw ProbeError.unavailable("Missing probe kernel")
        }
        let pipeline = try device.makeComputePipelineState(function: function)
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba16Float, width: 5, height: 1, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = [.shaderWrite, .shaderRead]
        guard let texture = device.makeTexture(descriptor: descriptor),
              let command = queue.makeCommandBuffer(),
              let encoder = command.makeComputeCommandEncoder() else {
            throw ProbeError.unavailable("Could not allocate probe resources")
        }
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(texture, index: 0)
        encoder.dispatchThreads(MTLSize(width: 5, height: 1, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 5, height: 1, depth: 1))
        encoder.endEncoding()
        command.commit()
        // Deliberate synchronous readback in this standalone diagnostic only.
        command.waitUntilCompleted()
        if let error = command.error { throw error }
        var data = [UInt16](repeating: 0, count: 20)
        data.withUnsafeMutableBytes {
            texture.getBytes($0.baseAddress!, bytesPerRow: 40,
                             from: MTLRegionMake2D(0, 0, 5, 1), mipmapLevel: 0)
        }
        let samples = stride(from: 0, to: data.count, by: 4).map { Float(Float16(bitPattern: data[$0])) }
        guard samples == [0, 0.125, 1, 4, 16] else { throw ProbeError.clipped(samples) }
        return GPUReport(device: device.name, unifiedMemory: device.hasUnifiedMemory,
                         physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                         recommendedGPUWorkingSetBytes: device.recommendedMaxWorkingSetSize,
                         rgba16FloatSamples: samples)
    }
}
