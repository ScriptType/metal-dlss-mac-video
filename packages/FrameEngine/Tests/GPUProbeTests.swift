import FrameEngine
import Metal
import Testing

@Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil, "Requires a Metal device"))
func floatTexturePreservesHDRHeadroom() throws {
    let report = try GPUProbe.run()
    #expect(report.rgba16FloatSamples == [0, 0.125, 1, 4, 16])
    #expect(report.recommendedGPUWorkingSetBytes > 0)
}
