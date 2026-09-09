import AVFoundation
import CoreVideo
import Foundation

public struct VideoReport: Codable, Sendable {
    public let file: String
    public let width: Int
    public let height: Int
    public let pixelFormat: String
    public let planeCount: Int
    public let presentationValue: Int64
    public let presentationTimescale: Int32
    public let colourAttachments: [String: String]
}

public enum VideoProbe {
    /// Decode one sample into 10-bit bi-planar CoreVideo storage and retain its colour tags.
    public static func run(url: URL) async throws -> VideoReport {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ProbeError.unavailable("No video track")
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw ProbeError.unavailable("Reader cannot add video output") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ProbeError.unavailable("Reader did not start") }
        defer { reader.cancelReading() }
        guard let sample = output.copyNextSampleBuffer(), let buffer = CMSampleBufferGetImageBuffer(sample) else {
            throw reader.error ?? ProbeError.unavailable("No decoded sample")
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let fourCC = String(bytes: [24, 16, 8, 0].map { UInt8((format >> $0) & 255) }, encoding: .ascii) ?? "unknown"
        let attachments = CVBufferCopyAttachments(buffer, .shouldPropagate) as? [String: Any] ?? [:]
        return VideoReport(file: url.lastPathComponent, width: CVPixelBufferGetWidth(buffer),
                           height: CVPixelBufferGetHeight(buffer), pixelFormat: fourCC,
                           planeCount: CVPixelBufferGetPlaneCount(buffer),
                           presentationValue: timestamp.value, presentationTimescale: timestamp.timescale,
                           colourAttachments: attachments.mapValues { String(describing: $0) })
    }
}
