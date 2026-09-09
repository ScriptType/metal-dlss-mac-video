import Testing
@testable import FrameEngine

@Test func modelAdmissionHoldsCapacityUntilItsOwnerFinishesAndRejectsOversizedWork() throws {
    let resources = HDRRuntimeResources()
    var policy = HDRRuntimeResourcePolicy()
    policy.maximumResidentModels = 2
    policy.maximumResidentModelBytes = 100
    policy.maximumProcessingPixels = 1000
    try resources.configure(policy)
    var first: HDRModelReservation? = try resources.reserve(payloadBytes: 60, processingPixels: 800)
    #expect(first != nil)
    #expect(throws: (any Error).self) { try resources.reserve(payloadBytes: 41, processingPixels: 1) }
    #expect(throws: (any Error).self) { try resources.reserve(payloadBytes: 1, processingPixels: 1001) }
    #expect(throws: (any Error).self) { try resources.configure(policy) }
    var second: HDRModelReservation? = try resources.reserve(payloadBytes: 40, processingPixels: 1000)
    #expect(second != nil)
    #expect(resources.snapshot().residentModelPayloadBytes == 100)
    #expect(throws: (any Error).self) { try resources.reserve(payloadBytes: 1, processingPixels: 1) }
    first = nil
    #expect(resources.snapshot().residentModels == 1)
    #expect(resources.snapshot().residentModelPayloadBytes == 40)
    second = nil
    #expect(resources.snapshot().residentModels == 0)
    #expect(resources.snapshot().residentModelPayloadBytes == 0)
    #expect(resources.snapshot().peakResidentModels == 2)
    try resources.configure(policy)
}
