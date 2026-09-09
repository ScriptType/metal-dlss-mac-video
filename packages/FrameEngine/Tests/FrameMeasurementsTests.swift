import Foundation
import Testing
@testable import FrameEngine

@Test func warmedMeasurementsUseCompletedWorkAndMarkUnavailableMetrics() throws {
    let configuration = MeasurementConfiguration(adapter: "test", source: "fixture", sourceWidth: 1920,
        sourceHeight: 1080, processingWidth: 320, processingHeight: 192, displayWidth: 3840, displayHeight: 2160,
        sourceFPS: 30, modelVersion: "hash", implementationRevision: "revision", settingsJSON: "{}", warmupFrames: 1)
    let recorder = FrameMeasurementRecorder(configuration: configuration)
    for i in 0..<4 {
        recorder.recordSubmission(seconds: 0.0001)
        recorder.recordCompletion(FrameMeasurement(generation: 1, frameID: UInt64(i), ptsValue: Int64(i),
            ptsTimescale: 30, submittedHostSeconds: Double(i), workerStartHostSeconds: Double(i) + 0.1,
            completedHostSeconds: Double(i) + 0.6, gpuStagesSeconds: ["import": 0.01], occupiedSlots: 3,
            retainedBytes: 100, deadlineHostSeconds: Double(i) + 0.5))
    }
    let report = recorder.report()
    #expect(report.warmedSamples == 3)
    #expect(report.completedThroughputFPS == 1)
    #expect(abs(try #require(report.completedWorkSeconds).p50 - 0.5) < 1e-10)
    #expect(report.cpuSubmissionSeconds?.p50 == 0.0001)
    #expect(report.gpuStageSeconds["import"]?.p50 == 0.01)
    #expect(report.avOffsetSeconds == nil)
    #expect(report.gpuCopies == nil)
    #expect(report.unavailableMetrics.contains("audio/video offset"))
    #expect(report.configuration.sourceWidth != report.configuration.processingWidth)
    #expect(report.configuration.displayWidth != report.configuration.sourceWidth)
    #expect(report.deadlineMisses == 3)
    recorder.recordPresentation(generation: 1, frameID: 3, hostSeconds: 3.7, avOffsetSeconds: 0.008)
    recorder.recordPresentation(generation: 1, frameID: 3, hostSeconds: 3.8, avOffsetSeconds: 0.008)
    let presented = recorder.report()
    #expect(presented.duplicatePresentations == 1)
    #expect(presented.avOffsetSeconds?.p50 == 0.008)
}

@Test func measurementTailIsBoundedAndDoesNotRelabelOldFramesAsWarmup() {
    let recorder = FrameMeasurementRecorder(configuration: .init(adapter: "test", source: "fixture",
        sourceWidth: 4, sourceHeight: 2, processingWidth: 4, processingHeight: 2, displayWidth: 4, displayHeight: 2,
        sourceFPS: 24, modelVersion: "none", implementationRevision: "test", settingsJSON: "{}", warmupFrames: 2),
        maximumSamples: 2)
    for i in 0..<5 {
        recorder.recordCompletion(FrameMeasurement(generation: 1, frameID: UInt64(i), ptsValue: Int64(i),
            ptsTimescale: 24, submittedHostSeconds: Double(i), workerStartHostSeconds: Double(i),
            completedHostSeconds: Double(i) + 1, gpuStagesSeconds: [:], occupiedSlots: 2, retainedBytes: 10,
            deadlineHostSeconds: nil))
    }
    let report = recorder.report()
    #expect(report.completedTotal == 5)
    #expect(report.retainedSamples == 2)
    #expect(report.warmedSamples == 2)
    #expect(report.measurementScope == "bounded tail of completed frames")
    #expect(report.frames.map(\.frameID) == [3, 4])
}
