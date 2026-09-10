import AppKit
import CoreMedia
import CoreVideo
import CryptoKit
import Foundation
import IOSurface
import QuartzCore
import ScreenCaptureKit

struct CaptureError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

struct Options {
    var pid: pid_t = 0
    var bundle = ""
    var window: CGWindowID = 0
    var list = false
    var preflight = false
    var canonical = false
    var sdrControl = false
    var scaleToFit = false
    var displayBound = false
    var output: URL?
    var reference: URL?

    init(_ arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let key = arguments[index]
            if key == "--list-windows" { list = true; index += 1; continue }
            if key == "--preflight" { preflight = true; index += 1; continue }
            if key == "--canonical" { canonical = true; index += 1; continue }
            if key == "--sdr-control" { sdrControl = true; index += 1; continue }
            if key == "--scale-to-fit" { scaleToFit = true; index += 1; continue }
            if key == "--display-bound" { displayBound = true; index += 1; continue }
            guard index + 1 < arguments.count else { throw CaptureError("Missing value for \(key)") }
            let value = arguments[index + 1]
            switch key {
            case "--owner-pid": pid = pid_t(value) ?? 0
            case "--owner-bundle": bundle = value
            case "--window-id": window = CGWindowID(value) ?? 0
            case "--output": output = URL(fileURLWithPath: value).standardizedFileURL
            case "--frame-reference": reference = URL(fileURLWithPath: value).standardizedFileURL
            default: throw CaptureError("Unknown option \(key)")
            }
            index += 2
        }
        if !preflight && (pid <= 0 || bundle.isEmpty || (!list && (window == 0 || output == nil))) {
            throw CaptureError("Require --owner-pid PID --owner-bundle ID and --window-id ID --output NEW_DIRECTORY; --list-windows omits window/output. Use unbundled for an allowed workspace CLI executable without a bundle.")
        }
        if canonical && sdrControl { throw CaptureError("SDR control cannot use canonical HDR intent") }
    }
}

func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
func canonical(_ url: URL) -> URL { url.standardizedFileURL.resolvingSymlinksInPath() }
func bundleName(_ value: String?) -> String { value.flatMap { $0.isEmpty ? nil : $0 } ?? "unbundled" }
func rect(_ value: CGRect) -> [String: Double] {
    ["x": value.origin.x, "y": value.origin.y, "width": value.width, "height": value.height]
}
func colorSpace(_ value: CGColorSpace) -> [String: Any] {
    var result: [String: Any] = ["name": value.name as String? ?? "unnamed", "model": value.model.rawValue]
    if let data = value.copyICCData() as Data? {
        result["iccBase64"] = data.base64EncodedString()
        result["iccSHA256"] = digest(data)
    }
    return result
}
func jsonValue(_ value: Any) -> Any {
    if let data = value as? Data { return ["type": "data", "base64": data.base64EncodedString(), "sha256": digest(data)] }
    let object = value as CFTypeRef
    if CFGetTypeID(object) == CGColorSpace.typeID {
        return colorSpace(unsafeBitCast(object, to: CGColorSpace.self))
    }
    if let dictionary = value as? NSDictionary {
        var result: [String: Any] = [:]
        for (key, item) in dictionary { result[String(describing: key)] = jsonValue(item) }
        return result
    }
    if let array = value as? NSArray { return array.map { jsonValue($0) } }
    if let number = value as? NSNumber { return number.doubleValue.isFinite ? number : ["nonfinite": number.stringValue] }
    if let text = value as? String { return text }
    if let geometry = value as? NSValue {
        return ["type": String(cString: geometry.objCType), "value": geometry.description]
    }
    return ["unserializedType": String(describing: type(of: value)), "description": String(describing: value)]
}
func time(_ value: CMTime) -> [String: Any] {
    ["value": value.value, "timescale": value.timescale, "epoch": value.epoch, "flags": value.flags.rawValue]
}
func writeJSON(_ value: Any, _ url: URL? = nil) throws {
    var data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    data.append(10)
    if let url { try data.write(to: url, options: .atomic) }
    else { FileHandle.standardOutput.write(data) }
}

@MainActor
func verifyProcess(_ options: Options) throws -> NSRunningApplication {
    guard let application = NSRunningApplication(processIdentifier: options.pid), !application.isTerminated,
          let executable = application.executableURL else { throw CaptureError("Target process unavailable") }
    let bundled: [String: String] = [
        "io.github.scripttype.hdr-player": "HDRPlayer",
        "dev.scripttype.HDRPiPProbe": "HDRPiPProbe",
        "com.apple.PIPAgent": "PIPAgent"
    ]
    let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let allowedCLI = ["artifacts/mpv-build/mpv", "artifacts/erika-target/debug/macos_native_demo", ".build/debug/HDRPlayer",
        "artifacts/hdr-native-color-probe/HDRNativeColorProbe"]
        .map { canonical(project.appendingPathComponent($0)) }
    let actualBundle = bundleName(application.bundleIdentifier)
    guard actualBundle == options.bundle else { throw CaptureError("Target bundle mismatch: expected \(options.bundle), observed \(actualBundle)") }
    guard bundled[actualBundle] == executable.lastPathComponent || allowedCLI.contains(canonical(executable)) else {
        throw CaptureError("Only HDR Player, HDRPiPProbe, PIPAgent or the workspace player executables are allowed")
    }
    return application
}

func verifyWindow(_ window: SCWindow, _ options: Options) throws {
    guard window.windowID == options.window, let owner = window.owningApplication,
          owner.processID == options.pid, bundleName(owner.bundleIdentifier) == options.bundle else {
        throw CaptureError("ScreenCaptureKit window ownership mismatch")
    }
    let info = CGWindowListCopyWindowInfo(.optionIncludingWindow, options.window) as? [[String: Any]] ?? []
    guard info.contains(where: { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == options.window &&
        ($0[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == options.pid }) else {
        throw CaptureError("Window identity changed or disappeared")
    }
}

func windowMetadata(_ window: SCWindow) -> [String: Any] {
    ["windowID": window.windowID, "ownerPID": window.owningApplication?.processID ?? 0,
     "ownerBundle": bundleName(window.owningApplication?.bundleIdentifier), "framePoints": rect(window.frame),
     "windowLayer": window.windowLayer, "isOnScreen": window.isOnScreen, "isActive": window.isActive]
}

@main
struct HDRCaptureProbe {
    @MainActor static func main() async {
        do {
            let options = try Options(Array(CommandLine.arguments.dropFirst()))
            let access = CGPreflightScreenCaptureAccess()
            if options.preflight {
                try writeJSON(["screenCapturePreflight": access, "permissionRequested": false, "captureAttempted": false])
                return
            }
            guard access else { throw CaptureError("Screen-capture preflight denied; no permission request will be made") }
            let application = try verifyProcess(options)
            let launchDate = application.launchDate
            let watchdog = DispatchSource.makeTimerSource(queue: .global())
            watchdog.schedule(deadline: .now() + 20)
            watchdog.setEventHandler {
                fputs("hdr-capture: operation exceeded 20 seconds\n", stderr)
                exit(124)
            }
            watchdog.resume()
            defer { watchdog.cancel() }

            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false)
            let windows = content.windows.filter { $0.owningApplication?.processID == options.pid &&
                bundleName($0.owningApplication?.bundleIdentifier) == options.bundle }
            if options.list {
                try writeJSON(["screenCapturePreflight": access, "captureAttempted": false,
                    "ownerPID": options.pid, "ownerBundle": options.bundle,
                    "ownerExecutable": application.executableURL!.path,
                    "windows": windows.map(windowMetadata), "titlesIncluded": false])
                return
            }
            guard let window = windows.first(where: { $0.windowID == options.window }), let output = options.output else {
                throw CaptureError("Explicit target window unavailable")
            }
            try verifyWindow(window, options)
            guard window.isOnScreen else { throw CaptureError("Target window is not on screen; refusing an off-screen compositor comparison") }
            guard !FileManager.default.fileExists(atPath: output.path) else { throw CaptureError("Output directory already exists") }
            let filter: SCContentFilter
            var visibleRect = window.frame
            if options.displayBound {
                // This inclusion filter explicitly excludes desktop, dock and
                // every other window. Record any explicit visible-edge crop.
                let displays = content.displays.filter { $0.frame.intersects(window.frame) }
                guard displays.count == 1, displays[0].frame.origin == .zero else {
                    throw CaptureError("Display-bound control requires one intersecting display at the logical origin")
                }
                visibleRect = window.frame.intersection(displays[0].frame)
                filter = SCContentFilter(display: displays[0], including: [window])
                filter.includeMenuBar = false
            } else { filter = SCContentFilter(desktopIndependentWindow: window) }
            let config = SCStreamConfiguration(preset: options.canonical ? .captureHDRScreenshotCanonicalDisplay : .captureHDRScreenshotLocalDisplay)
            if options.sdrControl {
                config.captureDynamicRange = .SDR
                config.pixelFormat = kCVPixelFormatType_32BGRA
                config.colorSpaceName = CGColorSpace.sRGB
            }
            config.showsCursor = false
            config.includeChildWindows = false
            config.ignoreShadowsSingleWindow = true
            config.ignoreShadowsDisplay = true
            config.ignoreGlobalClipSingleWindow = false
            let extent = visibleRect.size
            let scale = Double(filter.pointPixelScale)
            let width = Int((extent.width * scale).rounded())
            let height = Int((extent.height * scale).rounded())
            guard width > 0, height > 0, width <= 16384, height <= 16384, width * height <= 8_388_608 else {
                throw CaptureError("Capture dimensions exceed the 8-megapixel bound")
            }
            config.width = width; config.height = height
            config.scalesToFit = options.scaleToFit
            if options.displayBound { config.sourceRect = visibleRect }
            config.capturesAudio = false; config.captureMicrophone = false
            var report: [String: Any] = ["schemaVersion": 1, "screenCapturePreflight": true,
                "permissionRequested": false, "captureAttempted": true,
                "scope": "Explicit single-window ScreenCaptureKit HDR compositor pixels; no physical luminance or scanout measurement",
                "window": windowMetadata(window), "ownerExecutable": application.executableURL!.path,
                "ownerLaunchDate": launchDate.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown",
                "configuration": ["preset": options.canonical ? "HDRScreenshotCanonicalDisplay" : "HDRScreenshotLocalDisplay",
                    "pixelFormat": config.pixelFormat, "colorSpaceName": config.colorSpaceName as String,
                    "dynamicRange": config.captureDynamicRange.rawValue, "width": width, "height": height,
                    "pointPixelScale": scale, "contentRectPoints": rect(filter.contentRect),
                    "showsCursor": false, "includeChildWindows": false, "ignoreShadows": true,
                    "sdrControl": options.sdrControl, "displayBound": options.displayBound,
                    "scalesToFit": config.scalesToFit, "preservesAspectRatio": config.preservesAspectRatio,
                    "capturesShadowsOnly": config.capturesShadowsOnly,
                    "sourceRectPoints": rect(config.sourceRect), "destinationRectPixels": rect(config.destinationRect),
                    "visibleWindowRectPoints": rect(visibleRect), "windowClippedToDisplay": visibleRect != window.frame,
                    "captureResolution": config.captureResolution.rawValue],
                "screens": NSScreen.screens.map { ["framePoints": rect($0.frame), "backingScaleFactor": $0.backingScaleFactor,
                    "maximumExtendedDynamicRangeColorComponentValue": $0.maximumExtendedDynamicRangeColorComponentValue,
                    "maximumPotentialExtendedDynamicRangeColorComponentValue": $0.maximumPotentialExtendedDynamicRangeColorComponentValue,
                    "maximumReferenceExtendedDynamicRangeColorComponentValue": $0.maximumReferenceExtendedDynamicRangeColorComponentValue] }]
            if let reference = options.reference {
                let size = try reference.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
                guard size <= 65536 else { throw CaptureError("Frame reference exceeds 64 KiB") }
                let data = try Data(contentsOf: reference)
                guard data.count <= 65536 else { throw CaptureError("Frame reference exceeds 64 KiB") }
                report["callerFrameReference"] = ["sha256": digest(data), "json": try JSONSerialization.jsonObject(with: data),
                    "scope": "Caller-supplied identity; not inferred from screenshot timing or pixels"]
            }
            let beforeTicks = mach_absolute_time()
            var timebase = mach_timebase_info_data_t()
            mach_timebase_info(&timebase)
            let before = CACurrentMediaTime()
            let sample = try await SCScreenshotManager.captureSampleBuffer(contentFilter: filter, configuration: config)
            let after = CACurrentMediaTime()
            let afterTicks = mach_absolute_time()
            let current = try verifyProcess(options)
            guard !application.isTerminated, current.launchDate == launchDate else { throw CaptureError("Target process identity changed during capture") }
            try verifyWindow(window, options)
            let expectedFormat = options.sdrControl ? kCVPixelFormatType_32BGRA : kCVPixelFormatType_64RGBAHalf
            guard let buffer = CMSampleBufferGetImageBuffer(sample),
                  CVPixelBufferGetPixelFormatType(buffer) == expectedFormat,
                  !CVPixelBufferIsPlanar(buffer) else { throw CaptureError("Capture returned an unexpected pixel encoding; no implicit conversion performed") }
            let bytesPerPixel = options.sdrControl ? 4 : 8
            let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
            guard w > 0, h > 0, w <= 16384, h <= 16384, w * h <= 8_388_608, stride >= w * bytesPerPixel, stride <= w * bytesPerPixel + 65536,
                  stride * h <= 96 * 1024 * 1024 else { throw CaptureError("Invalid or oversized captured layout") }
            let copyStarted = CACurrentMediaTime()
            guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { throw CaptureError("Pixel readback lock failed") }
            var pixels = Data(repeating: 0, count: stride * h)
            do {
                defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
                guard let base = CVPixelBufferGetBaseAddress(buffer) else { throw CaptureError("Captured pixels unavailable") }
                pixels.withUnsafeMutableBytes { destination in
                    for row in 0..<h { memcpy(destination.baseAddress!.advanced(by: row * stride), base.advanced(by: row * stride), w * bytesPerPixel) }
                }
            }
            let copyEnded = CACurrentMediaTime()
            let pixelFile = options.sdrControl ? "pixels.bgra8" : "pixels.rgba16f"
            report["pixelStorage"] = ["file": pixelFile,
                "pixelFormat": CVPixelBufferGetPixelFormatType(buffer), "bytesPerPixel": bytesPerPixel,
                "encoding": options.sdrControl ? "BGRA unsigned8 SDR control; transfer/colorimetry from actual attachments" : "RGhA little-endian IEEE binary16 RGBA; transfer/colorimetry from actual attachments",
                "width": w, "height": h, "bytesPerRow": stride, "bytes": pixels.count,
                "sha256": digest(pixels), "padding": "source stride preserved; non-pixel row padding zeroed",
                "alpha": "Preserved without unpremultiplication; use actual alpha attachments, unknown if absent"]
            report["timing"] = ["requestedHostSeconds": before, "completedHostSeconds": after,
                "requestedMachTicks": beforeTicks, "completedMachTicks": afterTicks,
                "machTimebaseNumerator": timebase.numer, "machTimebaseDenominator": timebase.denom,
                "cpuReadbackStartedHostSeconds": copyStarted, "cpuReadbackCompletedHostSeconds": copyEnded,
                "samplePTS": time(CMSampleBufferGetPresentationTimeStamp(sample)),
                "sampleOutputPTS": time(CMSampleBufferGetOutputPresentationTimeStamp(sample)),
                "sampleDuration": time(CMSampleBufferGetDuration(sample)),
                "scope": "Capture request/completion and sample/WindowServer metadata, not source video PTS or physical scanout"]
            report["pixelAttachmentsPropagating"] = CVBufferCopyAttachments(buffer, .shouldPropagate).map(jsonValue) ?? [:]
            report["pixelAttachmentsNonPropagating"] = CVBufferCopyAttachments(buffer, .shouldNotPropagate).map(jsonValue) ?? [:]
            report["sampleAttachments"] = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false).map(jsonValue) ?? []
            report["sampleBufferAttachmentsPropagating"] = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample, attachmentMode: kCMAttachmentMode_ShouldPropagate).map(jsonValue) ?? [:]
            report["sampleBufferAttachmentsNonPropagating"] = CMCopyDictionaryOfAttachments(allocator: kCFAllocatorDefault, target: sample, attachmentMode: kCMAttachmentMode_ShouldNotPropagate).map(jsonValue) ?? [:]
            if let space = CVImageBufferGetColorSpace(buffer) { report["actualColorSpace"] = colorSpace(space.takeUnretainedValue()) }
            if let surface = CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() {
                report["surfaceContentHeadroom"] = IOSurfaceCopyValue(surface, kIOSurfaceContentHeadroom).map(jsonValue) ?? NSNull()
                report["surfaceICCProfile"] = IOSurfaceCopyValue(surface, kIOSurfaceICCProfile).map(jsonValue) ?? NSNull()
            }
            report["referenceWhiteNits"] = NSNull()
            report["referenceWhiteNote"] = "No universal ScreenCaptureKit reference-white-nits field. Half-float is not inherently linear; headroom is a ratio, not a luminance calibration."
            report["capturedUTC"] = ISO8601DateFormatter().string(from: Date())
            report["toolSHA256"] = digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])))
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            try pixels.write(to: output.appendingPathComponent(pixelFile), options: .atomic)
            try writeJSON(report, output.appendingPathComponent("report.json"))
            try writeJSON(["captured": true, "windowID": options.window, "report": output.appendingPathComponent("report.json").path])
        } catch {
            fputs("hdr-capture: \(error)\n", stderr)
            exit(1)
        }
    }
}
