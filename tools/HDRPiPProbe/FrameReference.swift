import AVFoundation
import CoreGraphics
import CoreVideo
import CryptoKit
import Foundation
import QuartzCore

struct ProbeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ message: String) { description = message }
}

func exactTime(_ time: CMTime) -> [String: Any] {
    ["value": time.value, "timescale": time.timescale, "numeric": time.isNumeric]
}

func fileDigest(_ url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var hash = SHA256()
    while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

final class FrameReference {
    let session: OpaquePointer
    let output: OpaquePointer
    let sample: CMSampleBuffer
    let pts, duration: CMTime
    let evidence: [String: Any]
    private var disposalEvidence: [String: Any]?

    init(session: OpaquePointer, output: OpaquePointer, sample: CMSampleBuffer,
         pts: CMTime, duration: CMTime, evidence: [String: Any]) {
        self.session = session; self.output = output; self.sample = sample
        self.pts = pts; self.duration = duration; self.evidence = evidence
    }

    func statistics() -> [String: Any] {
        var value = fe_statistics()
        fe_session_statistics(session, &value)
        return ["submitted": value.submitted, "completed": value.completed,
                "occupiedSlots": value.occupied_slots, "peakSlots": value.peak_slots]
    }

    @discardableResult func dispose() -> [String: Any] {
        if let disposalEvidence { return disposalEvidence }
        let began = CACurrentMediaTime()
        fe_output_release(output)
        fe_session_close(session)
        while fe_session_is_idle(session) == 0 { Thread.sleep(forTimeInterval: 0.002) }
        let result: [String: Any] = ["idleBeforeDestroy": true,
            "afterClose": statistics(), "drainSeconds": CACurrentMediaTime() - began]
        fe_session_destroy(session)
        disposalEvidence = result
        return result
    }
    deinit { dispose() }
}

private func attach(_ buffer: CVPixelBuffer, format: String) {
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                          kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
        format == "float" ? kCVImageBufferTransferFunction_Linear : kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
        .shouldPropagate)
    if format == "pq" {
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferChromaLocationTopFieldKey,
                              kCVImageBufferChromaLocation_Center, .shouldPropagate)
    } else if let space = CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020) {
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
    }
}

private func pqEncode(_ nits: Double) -> Double {
    let p = pow(max(0, min(10000, nits)) / 10000, 2610.0 / 16384)
    return pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)
}

private func pqDecode(_ code: Double) -> Double {
    let p = pow(max(0, min(1, code)), 32.0 / 2523)
    return 10000 * pow(max(p - 3424.0 / 4096, 0) / max(2413.0 / 128 - 2392.0 / 128 * p, 1e-12), 16384.0 / 2610)
}

private func convert(_ source: CVPixelBuffer, format: String) throws -> (CVPixelBuffer, [String: Any]) {
    let width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source)
    guard width % 2 == 0, height % 2 == 0, width * height <= 2_073_600,
          CVPixelBufferGetPixelFormatType(source) == kCVPixelFormatType_64RGBAHalf else {
        throw ProbeFailure("Probe requires even RGBA16F source geometry, at most1080p")
    }
    var destination: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:], kCVPixelBufferMetalCompatibilityKey: true] as CFDictionary
    let status = CVPixelBufferCreate(nil, width, height,
        format == "float" ? kCVPixelFormatType_64RGBAHalf : kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        attributes, &destination)
    guard status == kCVReturnSuccess, let destination else { throw ProbeFailure("Cannot allocate presentation surface") }
    CVPixelBufferLockBaseAddress(source, .readOnly)
    CVPixelBufferLockBaseAddress(destination, [])
    defer {
        CVPixelBufferUnlockBaseAddress(destination, [])
        CVPixelBufferUnlockBaseAddress(source, .readOnly)
    }
    let sourceRow = CVPixelBufferGetBytesPerRow(source) / MemoryLayout<Float16>.size
    let input = CVPixelBufferGetBaseAddress(source)!.assumingMemoryBound(to: Float16.self)
    var minimum = Double.infinity, maximum = -Double.infinity
    var negative = 0, abovePQ = 0, nonfinite = 0
    func value(_ x: Int, _ y: Int, _ c: Int) -> Double {
        Double(input[y * sourceRow + x * 4 + c])
    }
    for y in 0..<height { for x in 0..<width { for c in 0..<3 {
        let v = value(x, y, c)
        if !v.isFinite { nonfinite += 1; continue }
        minimum = min(minimum, v); maximum = max(maximum, v)
        negative += v < 0 ? 1 : 0; abovePQ += v > 10000 ? 1 : 0
    } } }
    guard nonfinite == 0 else { throw ProbeFailure("Nonfinite completed HDR components") }
    var maxError = 0.0, sumError = 0.0, squareError = 0.0
    func accumulate(_ reconstructed: Double, _ reference: Double) {
        let difference = abs(reconstructed - reference)
        maxError = max(maxError, difference); sumError += difference; squareError += difference * difference
    }
    if format == "float" {
        let output = CVPixelBufferGetBaseAddress(destination)!.assumingMemoryBound(to: Float16.self)
        let row = CVPixelBufferGetBytesPerRow(destination) / MemoryLayout<Float16>.size
        for y in 0..<height { for x in 0..<width {
            for c in 0..<3 {
                let original = value(x, y, c), encoded = Float16(original / 203)
                output[y * row + x * 4 + c] = encoded
                accumulate(Double(encoded) * 203, original)
            }
            output[y * row + x * 4 + 3] = 1
        } }
    } else {
        let luma = CVPixelBufferGetBaseAddressOfPlane(destination, 0)!.assumingMemoryBound(to: UInt16.self)
        let chroma = CVPixelBufferGetBaseAddressOfPlane(destination, 1)!.assumingMemoryBound(to: UInt16.self)
        let yRow = CVPixelBufferGetBytesPerRowOfPlane(destination, 0) / 2
        let uvRow = CVPixelBufferGetBytesPerRowOfPlane(destination, 1) / 2
        let kr = 0.2627, kb = 0.0593, kg = 1 - 0.2627 - 0.0593
        for y in stride(from: 0, to: height, by: 2) { for x in stride(from: 0, to: width, by: 2) {
            var cb = 0.0, cr = 0.0
            for dy in 0..<2 { for dx in 0..<2 {
                let r = pqEncode(value(x + dx, y + dy, 0))
                let g = pqEncode(value(x + dx, y + dy, 1))
                let b = pqEncode(value(x + dx, y + dy, 2))
                let yp = kr * r + kg * g + kb * b
                luma[(y + dy) * yRow + x + dx] = UInt16(max(64, min(940, (64 + 876 * yp).rounded()))) << 6
                cb += (b - yp) / (2 * (1 - kb)); cr += (r - yp) / (2 * (1 - kr))
            } }
            chroma[y / 2 * uvRow + x] = UInt16(max(64, min(960, (512 + 896 * cb / 4).rounded()))) << 6
            chroma[y / 2 * uvRow + x + 1] = UInt16(max(64, min(960, (512 + 896 * cr / 4).rounded()))) << 6
        } }
        // Decode the actual quantized420 surface. Error includes chroma
        // subsampling and10-bit quantization, separately from source clipping.
        for y in 0..<height { for x in 0..<width {
            let yp = (Double(luma[y * yRow + x] >> 6) - 64) / 876
            let uv = y / 2 * uvRow + x / 2 * 2
            let cb = (Double(chroma[uv] >> 6) - 512) / 896
            let cr = (Double(chroma[uv + 1] >> 6) - 512) / 896
            let r = yp + 2 * (1 - kr) * cr, b = yp + 2 * (1 - kb) * cb
            let g = (yp - kr * r - kb * b) / kg
            for (c, encoded) in [r, g, b].enumerated() {
                accumulate(pqDecode(encoded), max(0, min(10000, value(x, y, c))))
            }
        } }
    }
    attach(destination, format: format)
    let count = Double(width * height * 3)
    return (destination, ["format": format == "float" ? "RGBA16F extended linearBT2020" : "PQ P010 limited-range BT2020 NCL420",
        "width": width, "height": height, "inputMinimumNits": minimum, "inputMaximumNits": maximum,
        "negativeInputComponents": negative, "above10000NitComponents": abovePQ,
        "clippedComponents": format == "pq" ? negative + abovePQ : 0,
        "numericRoundTripMaximumErrorNits": maxError, "numericRoundTripMeanErrorNits": sumError / count,
        "numericRoundTripRMSErrorNits": sqrt(squareError / count),
        "referenceDomain": format == "float" ? "original absolute nits; stored float divided by203" : "input clipped to0...10000nits; error includes420 chroma subsampling and10bit quantization",
        "colourInterpretationEstablished": format == "pq",
        "colourLimitation": format == "float" ? "Relative linear unity is normalized to203nit reference white; AVKit physical reference-white mapping is unverified" : "ST2084 absolute-nit coding is explicit; physical display accuracy is unmeasured",
        "fullFrameCPUReadbacks": 1, "cpuSurfaceWrites": 1, "frameworkInternalCopies": "unmeasured"])
}

func makeFrameReference(source: URL, model: URL?, format: String) async throws -> FrameReference {
    let asset = AVURLAsset(url: source)
    guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw ProbeFailure("No video track") }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
        kCVPixelBufferMetalCompatibilityKey as String: true,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw ProbeFailure("Cannot attach planar video decoder") }
    let provider = reader.outputProvider(for: output)
    guard reader.startReading(), let sourceSample = try await provider.next(),
          case .pixelBuffer(let image) = sourceSample.content else { throw ProbeFailure("Cannot decode first HDR source frame") }
    let buffer = image.withUnsafeBuffer { $0 }
    defer { reader.cancelReading() }
    let pts = sourceSample.outputPresentationTimeStamp.isNumeric
        ? sourceSample.outputPresentationTimeStamp : sourceSample.presentationTimeStamp
    guard pts.isNumeric else { throw ProbeFailure("Decoded source sample has no numeric PTS") }
    var duration = sourceSample.outputDuration
    var durationOrigin = "decoded sample outputDuration"
    var nextPTS: CMTime?
    if !duration.isNumeric || duration <= .zero {
        duration = sourceSample.duration
        durationOrigin = "decoded sample duration"
    }
    if !duration.isNumeric || duration <= .zero {
        guard let next = try await provider.next(), case .pixelBuffer = next.content else {
            throw ProbeFailure("Source duration absent and no following decoded image supplies an exact interval")
        }
        let nextTime = next.outputPresentationTimeStamp.isNumeric
            ? next.outputPresentationTimeStamp : next.presentationTimeStamp
        guard nextTime.isNumeric, nextTime > pts else {
            throw ProbeFailure("Source duration absent and next decoded image has no later exact PTS")
        }
        duration = CMTimeSubtract(nextTime, pts)
        nextPTS = nextTime
        durationOrigin = "interval to next decoded image PTS; explicit held-frame display interval"
    }
    let timingEvidence: [String: Any] = [
        "ptsOrigin": sourceSample.outputPresentationTimeStamp.isNumeric ? "decoded outputPresentationTimeStamp" : "decoded presentationTimeStamp",
        "samplePTS": exactTime(sourceSample.presentationTimeStamp),
        "sampleOutputPTS": exactTime(sourceSample.outputPresentationTimeStamp),
        "sampleDuration": exactTime(sourceSample.duration),
        "sampleOutputDuration": exactTime(sourceSample.outputDuration),
        "durationOrigin": durationOrigin, "nextDecodedPTS": nextPTS.map(exactTime) as Any? ?? NSNull(),
        "nominalFrameRateAssumption": false]
    let transfer = CVBufferCopyAttachment(buffer, kCVImageBufferTransferFunctionKey, nil) as? String
    let primaries = CVBufferCopyAttachment(buffer, kCVImageBufferColorPrimariesKey, nil) as? String
    guard primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String,
          transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String || transfer == kCVImageBufferTransferFunction_ITU_R_2100_HLG as String else {
        throw ProbeFailure("Probe source must explicitly declare PQ/HLG andBT2020")
    }
    var error = [CChar](repeating: 0, count: 2048)
    var configuration = fe_config()
    configuration.struct_size = UInt32(MemoryLayout<fe_config>.size); configuration.abi_version = UInt32(FE_ABI_VERSION)
    configuration.max_in_flight = 3; configuration.memory_limit_bytes = 536_870_912
    configuration.processing_width = 32; configuration.processing_height = 24
    configuration.reference_white_nits = 203; configuration.effect_strength = model == nil ? 0 : 1
    configuration.colour_strength = 1; configuration.maximum_luminance_ratio = 2
    let session = (model?.path ?? "").withCString { path -> OpaquePointer? in
        configuration.model_path = model == nil ? nil : path
        return fe_session_create(&configuration, &error, error.count)
    }
    guard let session else { throw ProbeFailure(String(cString: error)) }
    var lease: OpaquePointer?
    do {
        var frame = fe_frame()
        frame.struct_size = UInt32(MemoryLayout<fe_frame>.size); frame.abi_version = UInt32(FE_ABI_VERSION)
        frame.source_id = 1; frame.stream_id = 1; frame.frame_id = 1; frame.generation = fe_session_generation(session)
        frame.pts = fe_time(value: pts.value, timescale: pts.timescale)
        frame.duration = fe_time(value: duration.value, timescale: duration.timescale)
        frame.geometry.width = UInt32(CVPixelBufferGetWidth(buffer)); frame.geometry.height = UInt32(CVPixelBufferGetHeight(buffer))
        frame.geometry.crop_width = Double(frame.geometry.width); frame.geometry.crop_height = Double(frame.geometry.height)
        frame.geometry.pixel_aspect_num = 1; frame.geometry.pixel_aspect_den = 1
        frame.colour.primaries = FE_BT2020.rawValue
        frame.colour.transfer = transfer == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String ? FE_PQ.rawValue : FE_HLG.rawValue
        frame.colour.matrix = FE_YUV2020.rawValue; frame.colour.range = FE_VIDEO_RANGE.rawValue
        frame.colour.reference_white_nits = 203; frame.colour.hlg_peak_nits = 1000; frame.colour.chroma_location = 1
        frame.pixel_format = CVPixelBufferGetPixelFormatType(buffer); frame.plane_count = UInt32(CVPixelBufferGetPlaneCount(buffer))
        frame.planes.0 = fe_plane(width: UInt32(CVPixelBufferGetWidthOfPlane(buffer, 0)), height: UInt32(CVPixelBufferGetHeightOfPlane(buffer, 0)), bytes_per_row: UInt32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)), offset: 0)
        frame.planes.1 = fe_plane(width: UInt32(CVPixelBufferGetWidthOfPlane(buffer, 1)), height: UInt32(CVPixelBufferGetHeightOfPlane(buffer, 1)), bytes_per_row: UInt32(CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)), offset: 0)
        frame.pixel_buffer = Unmanaged.passUnretained(buffer).toOpaque()
        guard fe_session_submit(session, &frame) == FE_ACCEPTED else { throw ProbeFailure("Engine rejected the source frame") }
        let deadline = CACurrentMediaTime() + 30
        while lease == nil && CACurrentMediaTime() < deadline {
            let result = fe_session_poll(session, &lease)
            guard result == FE_EMPTY || result == FE_ACCEPTED else {
                _ = fe_session_error(session, &error, error.count)
                throw ProbeFailure(String(cString: error))
            }
            if lease == nil { try await Task.sleep(nanoseconds: 2_000_000) }
        }
        guard let lease, let descriptor = fe_output_frame(lease)?.pointee,
              let pixels = descriptor.pixel_buffer else { throw ProbeFailure("Engine completion timed out") }
        guard descriptor.pts.value == pts.value, descriptor.pts.timescale == pts.timescale,
              descriptor.colour.transfer == FE_LINEAR.rawValue, descriptor.colour.primaries == FE_BT2020.rawValue else {
            throw ProbeFailure("Completed engine frame changed exact source timing or HDR working contract")
        }
        let original = Unmanaged<CVPixelBuffer>.fromOpaque(pixels).takeUnretainedValue()
        let (presented, conversion) = try convert(original, format: format)
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: presented,
            formatDescriptionOut: &description) == noErr, let description else { throw ProbeFailure("Cannot describe completed presentation buffer") }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: presented,
            formatDescription: description, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
            let sample else { throw ProbeFailure("Cannot package completed frame") }
        var redraw: OpaquePointer?
        guard fe_session_redraw(session, &redraw) == FE_ACCEPTED, let redraw else { throw ProbeFailure("No retained redraw output") }
        let retainedIdentity = fe_output_frame(redraw)?.pointee.pixel_buffer == pixels
        fe_output_release(redraw)
        return FrameReference(session: session, output: lease, sample: sample, pts: pts, duration: duration,
            evidence: ["source": source.path, "model": model?.path as Any? ?? NSNull(),
                "sourcePTS": exactTime(pts), "sourceDuration": exactTime(duration),
                "processingWidth": configuration.processing_width, "processingHeight": configuration.processing_height,
                "strength": configuration.effect_strength, "colourStrength": configuration.colour_strength,
                "referenceWhiteNits": configuration.reference_white_nits, "maximumLuminanceRatio": configuration.maximum_luminance_ratio,
                "timingProvenance": timingEvidence, "sourceSHA256": try fileDigest(source),
                "generation": descriptor.generation, "frameID": descriptor.frame_id,
                "contentKind": fe_output_content_kind(lease).rawValue, "retainedRedrawIdentity": retainedIdentity,
                "conversion": conversion, "sourceTransfer": transfer ?? "unknown",
                "scope": "one completed frame held across PiP; streaming/audio synchronization unqualified"])
    } catch {
        if let lease { fe_output_release(lease) }
        fe_session_close(session)
        while fe_session_is_idle(session) == 0 { try? await Task.sleep(nanoseconds: 2_000_000) }
        fe_session_destroy(session)
        throw error
    }
}
