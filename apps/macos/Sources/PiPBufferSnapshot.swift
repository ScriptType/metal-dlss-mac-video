import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import CryptoKit

/// Explicit diagnostic readback only. Normal playback never calls this helper.
@MainActor
enum PiPBufferSnapshot {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func rect(_ value: CGRect) -> [CGFloat] {
        [value.origin.x, value.origin.y, value.width, value.height]
    }
    static func json(_ value: Any, depth: Int = 0) -> Any {
        guard depth < 12 else { return ["truncated": true] }
        if let data = value as? Data {
            return ["bytes": data.count, "sha256": digest(data), "base64": data.count <= 65536 ? data.base64EncodedString() : "omitted"]
        }
        let object = value as CFTypeRef
        if CFGetTypeID(object) == CGColorSpace.typeID {
            let color = unsafeDowncast(object, to: CGColorSpace.self)
            var result: [String: Any] = ["name": color.name as String? ?? "unnamed", "model": color.model.rawValue]
            if let data = color.copyICCData() as Data? { result["icc"] = json(data, depth: depth + 1) }
            return result
        }
        if let dictionary = value as? NSDictionary {
            var result: [String: Any] = [:]
            for (key, item) in dictionary { result[String(describing: key)] = json(item, depth: depth + 1) }
            return result
        }
        if let array = value as? NSArray { return array.prefix(256).map { json($0, depth: depth + 1) } }
        if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : ["nonfinite": number.stringValue] }
        if let text = value as? String { return text }
        return ["type": String(describing: type(of: value)), "description": String(describing: value)]
    }
    static func format(_ description: CMVideoFormatDescription) -> [String: Any] {
        let dimensions = CMVideoFormatDescriptionGetDimensions(description)
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(description, usePixelAspectRatio: true, useCleanAperture: true)
        return ["dimensions": [dimensions.width, dimensions.height], "mediaSubType": CMFormatDescriptionGetMediaSubType(description),
            "cleanApertureTopLeft": rect(CMVideoFormatDescriptionGetCleanAperture(description, originIsAtTopLeft: true)),
            "presentationDimensions": [presentation.width, presentation.height],
            "extensions": json(CMFormatDescriptionGetExtensions(description) as Any)]
    }
    static func layer(_ layer: AVSampleBufferDisplayLayer, host: NSView?) -> [String: Any] {
        let t = layer.transform, a = layer.affineTransform()
        var result: [String: Any] = ["frame": rect(layer.frame), "bounds": rect(layer.bounds),
            "contentsRect": rect(layer.contentsRect), "contentsCenter": rect(layer.contentsCenter),
            "contentsScale": layer.contentsScale, "contentsGravity": layer.contentsGravity.rawValue,
            "videoGravity": layer.videoGravity.rawValue, "position": [layer.position.x, layer.position.y],
            "anchorPoint": [layer.anchorPoint.x, layer.anchorPoint.y], "masksToBounds": layer.masksToBounds,
            "hidden": layer.isHidden, "opacity": layer.opacity,
            "affineTransform": [a.a, a.b, a.c, a.d, a.tx, a.ty],
            "transform": [t.m11,t.m12,t.m13,t.m14,t.m21,t.m22,t.m23,t.m24,t.m31,t.m32,t.m33,t.m34,t.m41,t.m42,t.m43,t.m44],
            "rendererStatus": layer.sampleBufferRenderer.status.rawValue]
        if let host {
            result["host"] = ["frame": rect(host.frame), "bounds": rect(host.bounds), "flipped": host.isFlipped,
                "backingScale": host.window?.backingScaleFactor ?? 0,
                "layerContentsScale": host.layer?.contentsScale ?? 0,
                "frameInWindow": rect(host.convert(host.bounds, to: nil))]
            result["superlayerIsHostLayer"] = layer.superlayer === host.layer
        }
        if let parent = layer.superlayer {
            result["superlayer"] = ["class": String(describing: type(of: parent)), "frame": rect(parent.frame),
                "bounds": rect(parent.bounds), "contentsScale": parent.contentsScale]
        }
        if let presentation = layer.presentation() {
            result["presentation"] = ["frame": rect(presentation.frame), "bounds": rect(presentation.bounds),
                "contentsScale": presentation.contentsScale, "contentsRect": rect(presentation.contentsRect)]
        }
        return result
    }
    static func write(_ pixel: CVPixelBuffer, name: String, directory: URL) throws -> [String: Any] {
        let width = CVPixelBufferGetWidth(pixel), height = CVPixelBufferGetHeight(pixel)
        let stride = CVPixelBufferGetBytesPerRow(pixel), code = CVPixelBufferGetPixelFormatType(pixel)
        var result: [String: Any] = ["available": true, "width": width, "height": height, "bytesPerRow": stride,
            "pixelFormat": code, "planar": CVPixelBufferIsPlanar(pixel), "planeCount": CVPixelBufferGetPlaneCount(pixel),
            "attachmentsPropagating": json(CVBufferCopyAttachments(pixel, .shouldPropagate) as Any),
            "attachmentsNonPropagating": json(CVBufferCopyAttachments(pixel, .shouldNotPropagate) as Any)]
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &description)
        result["formatDescriptionStatus"] = status
        if let description { result["formatDescription"] = format(description) }
        guard code == kCVPixelFormatType_64RGBAHalf || code == kCVPixelFormatType_32BGRA,
              !CVPixelBufferIsPlanar(pixel), width > 0, width <= 4096, height > 0, height <= 2160,
              stride >= width * (code == kCVPixelFormatType_64RGBAHalf ? 8 : 4), stride <= 131072,
              stride * height <= 64 * 1024 * 1024 else {
            result["pixelsCopied"] = false; result["reason"] = "Unsupported format or diagnostic size bound"; return result
        }
        guard CVPixelBufferLockBaseAddress(pixel, .readOnly) == kCVReturnSuccess else { throw Failure("Could not lock \(name) pixel buffer") }
        defer { CVPixelBufferUnlockBaseAddress(pixel, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pixel) else { throw Failure("No \(name) pixel base address") }
        let rowBytes = width * (code == kCVPixelFormatType_64RGBAHalf ? 8 : 4)
        var bytes = Data(count: stride * height)
        bytes.withUnsafeMutableBytes { destination in
            for y in 0..<height { memcpy(destination.baseAddress!.advanced(by: y * stride), base.advanced(by: y * stride), rowBytes) }
        }
        let filename = name + (code == kCVPixelFormatType_64RGBAHalf ? ".rgba16f" : ".bgra8")
        try bytes.write(to: directory.appendingPathComponent(filename), options: .atomic)
        result["pixelsCopied"] = true; result["file"] = filename; result["byteCount"] = bytes.count
        result["sha256"] = digest(bytes); result["rowPadding"] = "zeroed; component bytes unchanged"
        return result
    }
}
