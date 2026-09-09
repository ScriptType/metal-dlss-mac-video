import CFrameEngine
import Foundation

func writeError(_ message: String, _ pointer: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    let bytes = Array(message.utf8CString)
    if let pointer, capacity > 0 {
        let count = min(capacity - 1, bytes.count - 1)
        for i in 0..<count { pointer[i] = bytes[i] }
        pointer[count] = 0
    }
    return bytes.count
}

func validatedFrameConfiguration(_ config: UnsafePointer<fe_config>?) throws -> (limits: FrameSessionLimits, pipeline: HDRPipelineConfiguration) {
    guard let config = config?.pointee, config.abi_version == FE_ABI_VERSION,
          config.struct_size >= MemoryLayout<fe_config>.size,
          config.reference_white_nits.isFinite, config.reference_white_nits > 0,
          config.effect_strength.isFinite, (0...1).contains(config.effect_strength),
          config.colour_strength.isFinite, (0...1).contains(config.colour_strength),
          config.maximum_luminance_ratio.isFinite, config.maximum_luminance_ratio >= 1 else {
        throw FrameEngineError.invalid("Invalid configuration ABI or HDR settings")
    }
    let limits = FrameSessionLimits(slots: Int(config.max_in_flight), bytes: config.memory_limit_bytes,
        processingWidth: Int(config.processing_width), processingHeight: Int(config.processing_height))
    let configuration = HDRPipelineConfiguration(
        modelURL: config.model_path.map { URL(fileURLWithPath: String(cString: $0)) },
        modelVersion: config.model_version.map { String(cString: $0) } ?? "original",
        processingWidth: Int(config.processing_width), processingHeight: Int(config.processing_height),
        strength: Float(config.effect_strength), colourStrength: Float(config.colour_strength),
        maximumLuminanceRatio: Float(config.maximum_luminance_ratio), referenceWhiteNits: Float(config.reference_white_nits))
    return (limits, configuration)
}

@_cdecl("fe_session_create")
public func feSessionCreate(_ config: UnsafePointer<fe_config>?, _ error: UnsafeMutablePointer<CChar>?,
                            _ capacity: Int) -> UnsafeMutableRawPointer? {
    do {
        let (limits, configuration) = try validatedFrameConfiguration(config)
        let session = try FrameSession(limits: limits, processor: HDRPipelineProcessor(configuration: configuration))
        _ = writeError("", error, capacity)
        return Unmanaged.passRetained(session).toOpaque()
    } catch let failure {
        _ = writeError(failure.localizedDescription, error, capacity)
        return nil
    }
}

private func session(_ pointer: UnsafeMutableRawPointer) -> FrameSession {
    Unmanaged<FrameSession>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("fe_session_submit")
public func feSessionSubmit(_ pointer: UnsafeMutableRawPointer?, _ frame: UnsafePointer<fe_frame>?) -> Int32 {
    guard let pointer, let frame else { return Int32(FE_FAILED.rawValue) }
    return Int32(session(pointer).submit(frame.pointee).rawValue)
}

@_cdecl("fe_session_poll")
public func feSessionPoll(_ pointer: UnsafeMutableRawPointer?, _ output: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    output?.pointee = nil
    guard let pointer, let output else { return Int32(FE_FAILED.rawValue) }
    guard let frame = session(pointer).poll() else { return Int32(FE_EMPTY.rawValue) }
    output.pointee = Unmanaged.passRetained(frame).toOpaque()
    return Int32(FE_ACCEPTED.rawValue)
}

@_cdecl("fe_session_redraw")
public func feSessionRedraw(_ pointer: UnsafeMutableRawPointer?, _ output: UnsafeMutablePointer<UnsafeMutableRawPointer?>?) -> Int32 {
    output?.pointee = nil
    guard let pointer, let output else { return Int32(FE_FAILED.rawValue) }
    guard let frame = session(pointer).redraw() else { return Int32(FE_EMPTY.rawValue) }
    output.pointee = Unmanaged.passRetained(frame).toOpaque()
    return Int32(FE_ACCEPTED.rawValue)
}

@_cdecl("fe_output_frame")
public func feOutputFrame(_ pointer: UnsafeRawPointer?) -> UnsafePointer<fe_frame>? {
    guard let pointer else { return nil }
    return Unmanaged<CompletedFrame>.fromOpaque(pointer).takeUnretainedValue().descriptorPointer
}

@_cdecl("fe_output_release")
public func feOutputRelease(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer { Unmanaged<CompletedFrame>.fromOpaque(pointer).release() }
}

@_cdecl("fe_session_generation")
public func feSessionGeneration(_ pointer: UnsafeMutableRawPointer?) -> UInt64 {
    pointer.map { session($0).generation } ?? 0
}

@_cdecl("fe_session_reset")
public func feSessionReset(_ pointer: UnsafeMutableRawPointer?) -> UInt64 {
    pointer.map { session($0).reset() } ?? 0
}

@_cdecl("fe_session_statistics")
public func feSessionStatistics(_ pointer: UnsafeMutableRawPointer?, _ statistics: UnsafeMutablePointer<fe_statistics>?) {
    guard let pointer, let statistics else { return }
    let s = session(pointer).statistics()
    statistics.pointee = fe_statistics(submitted: s.submitted, completed: s.completed, cancelled: s.cancelled,
        failures: s.failures, duplicate_submissions: s.duplicates, retained_bytes: s.retainedBytes,
        peak_retained_bytes: s.peakRetainedBytes, occupied_slots: UInt32(s.occupiedSlots),
        peak_slots: UInt32(s.peakSlots), last_completed_seconds: s.lastCompletedSeconds)
}

@_cdecl("fe_session_error")
public func feSessionError(_ pointer: UnsafeMutableRawPointer?, _ error: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    writeError(pointer.map { session($0).error } ?? "Null session", error, capacity)
}

@_cdecl("fe_session_measurements_configure")
public func feSessionMeasurementsConfigure(_ pointer: UnsafeMutableRawPointer?, _ json: UnsafePointer<CChar>?) -> Int32 {
    guard let pointer, let json else { return Int32(FE_FAILED.rawValue) }
    do {
        let configuration = try JSONDecoder().decode(MeasurementConfiguration.self, from: Data(String(cString: json).utf8))
        guard configuration.sourceFPS.isFinite, configuration.sourceFPS > 0,
              configuration.sourceWidth > 0, configuration.sourceHeight > 0,
              configuration.processingWidth > 0, configuration.processingHeight > 0,
              configuration.displayWidth > 0, configuration.displayHeight > 0,
              configuration.warmupFrames >= 0 else { return Int32(FE_FAILED.rawValue) }
        return Int32(session(pointer).configureMeasurements(configuration) ? FE_ACCEPTED.rawValue : FE_FAILED.rawValue)
    } catch { return Int32(FE_FAILED.rawValue) }
}

@_cdecl("fe_session_record_presentation")
public func feSessionRecordPresentation(_ pointer: UnsafeMutableRawPointer?, _ generation: UInt64, _ frameID: UInt64,
                                         _ hostSeconds: Double, _ avOffsetSeconds: Double) {
    guard let pointer, hostSeconds.isFinite, hostSeconds > 0 else { return }
    session(pointer).measurements?.recordPresentation(generation: generation, frameID: frameID,
        hostSeconds: hostSeconds, avOffsetSeconds: avOffsetSeconds.isFinite ? avOffsetSeconds : nil)
}

@_cdecl("fe_session_record_drop")
public func feSessionRecordDrop(_ pointer: UnsafeMutableRawPointer?, _ generation: UInt64, _ frameID: UInt64) {
    if let pointer { session(pointer).measurements?.recordDrop(generation: generation, frameID: frameID) }
}

@_cdecl("fe_session_record_transfers")
public func feSessionRecordTransfers(_ pointer: UnsafeMutableRawPointer?, _ generation: UInt64, _ frameID: UInt64,
                                     _ gpuCopies: Int32, _ cpuReadbacks: Int32, _ cpuWaits: Int32) {
    guard let pointer, gpuCopies >= 0, cpuReadbacks >= 0, cpuWaits >= 0 else { return }
    session(pointer).measurements?.recordTransfers(generation: generation, frameID: frameID,
        gpuCopies: Int(gpuCopies), cpuReadbacks: Int(cpuReadbacks), cpuWaits: Int(cpuWaits))
}

@_cdecl("fe_session_record_seek")
public func feSessionRecordSeek(_ pointer: UnsafeMutableRawPointer?, _ seconds: Double) {
    if let pointer { session(pointer).measurements?.recordSeek(seconds: seconds) }
}

@_cdecl("fe_session_record_energy")
public func feSessionRecordEnergy(_ pointer: UnsafeMutableRawPointer?, _ joules: Double) {
    if let pointer { session(pointer).measurements?.recordEnergy(joules: joules) }
}

@_cdecl("fe_session_measurements_json")
public func feSessionMeasurementsJSON(_ pointer: UnsafeMutableRawPointer?, _ json: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    guard let pointer, let recorder = session(pointer).measurements,
          let data = try? JSONEncoder().encode(recorder.report()) else { return writeError("{}", json, capacity) }
    return writeError(String(decoding: data, as: UTF8.self), json, capacity)
}

@_cdecl("fe_session_destroy")
public func feSessionDestroy(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    let owner = Unmanaged<FrameSession>.fromOpaque(pointer)
    owner.takeUnretainedValue().close()
    owner.release()
}

@_cdecl("fe_session_close")
public func feSessionClose(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer { session(pointer).close() }
}

@_cdecl("fe_session_is_idle")
public func feSessionIsIdle(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let pointer else { return 1 }
    return session(pointer).isIdle ? 1 : 0
}
