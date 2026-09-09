import CFrameEngine
import Foundation

private final class PreparedFrameEngineHandle: @unchecked Sendable {
    let context: PreparedHDRContext
    let limits: FrameSessionLimits
    init(context: PreparedHDRContext, limits: FrameSessionLimits) {
        self.context = context; self.limits = limits
        context.initializeInBackground()
    }
}

private func preparedHandle(_ pointer: UnsafeMutableRawPointer) -> PreparedFrameEngineHandle {
    Unmanaged<PreparedFrameEngineHandle>.fromOpaque(pointer).takeUnretainedValue()
}

@_cdecl("fe_prepared_create")
public func fePreparedCreate(_ config: UnsafePointer<fe_config>?, _ json: UnsafePointer<CChar>?,
                             _ actualSourcePath: UnsafePointer<CChar>?,
                             _ error: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> UnsafeMutableRawPointer? {
    createPrepared(config, json, actualSourcePath, decoder: nil, error, capacity)
}

@_cdecl("fe_prepared_create_with_decoder")
public func fePreparedCreateWithDecoder(_ config: UnsafePointer<fe_config>?, _ json: UnsafePointer<CChar>?,
                             _ actualSourcePath: UnsafePointer<CChar>?, _ decoder: UnsafePointer<fe_preparation_decoder_provider>?,
                             _ error: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> UnsafeMutableRawPointer? {
    guard let decoder else { _ = writeError("Prepared decoder provider is required", error, capacity); return nil }
    return createPrepared(config, json, actualSourcePath, decoder: decoder, error, capacity)
}

private func createPrepared(_ config: UnsafePointer<fe_config>?, _ json: UnsafePointer<CChar>?,
                           _ actualSourcePath: UnsafePointer<CChar>?, decoder: UnsafePointer<fe_preparation_decoder_provider>?,
                           _ error: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> UnsafeMutableRawPointer? {
    do {
        let (limits, configuration) = try validatedFrameConfiguration(config)
        guard let json, let actualSourcePath else { throw FrameEngineError.invalid("Prepared configuration and actual opened source are required") }
        let request = try JSONDecoder().decode(PreparedHDRRequest.self, from: Data(String(cString: json).utf8))
        let declared = URL(fileURLWithPath: request.sourcePath).standardizedFileURL.resolvingSymlinksInPath()
        let actual = URL(fileURLWithPath: String(cString: actualSourcePath)).standardizedFileURL.resolvingSymlinksInPath()
        guard declared == actual else { throw FrameEngineError.invalid("Prepared source differs from the file opened by playback") }
        let provider: any FramePreparationDecoderProvider = try decoder.map { try CFramePreparationProvider($0) } ?? NativeFramePreparationProvider()
        let context = try PreparedHDRContext(request: request, configuration: configuration, decoderProvider: provider)
        let handle = PreparedFrameEngineHandle(context: context, limits: limits)
        _ = writeError("", error, capacity)
        return Unmanaged.passRetained(handle).toOpaque()
    } catch let failure {
        _ = writeError(failure.localizedDescription, error, capacity)
        return nil
    }
}

@_cdecl("fe_prepared_session_create")
public func fePreparedSessionCreate(_ pointer: UnsafeMutableRawPointer?, _ error: UnsafeMutablePointer<CChar>?,
                                    _ capacity: Int) -> UnsafeMutableRawPointer? {
    do {
        guard let pointer else { throw FrameEngineError.invalid("Null Prepared context") }
        let handle = preparedHandle(pointer)
        let session = try FrameSession(limits: handle.limits, processor: PreparedFrameProcessor(context: handle.context))
        _ = writeError("", error, capacity)
        return Unmanaged.passRetained(session).toOpaque()
    } catch let failure {
        _ = writeError(failure.localizedDescription, error, capacity)
        return nil
    }
}

@_cdecl("fe_prepared_start")
public func fePreparedStart(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let pointer else { return Int32(FE_FAILED.rawValue) }
    preparedHandle(pointer).context.requestStart()
    return Int32(FE_ACCEPTED.rawValue)
}

@_cdecl("fe_prepared_cancel")
public func fePreparedCancel(_ pointer: UnsafeMutableRawPointer?) {
    if let pointer { preparedHandle(pointer).context.requestCancel() }
}

@_cdecl("fe_prepared_is_idle")
public func fePreparedIsIdle(_ pointer: UnsafeMutableRawPointer?) -> Int32 {
    guard let pointer else { return 1 }
    return preparedHandle(pointer).context.status.snapshot().isIdle ? 1 : 0
}

@_cdecl("fe_prepared_progress_json")
public func fePreparedProgressJSON(_ pointer: UnsafeMutableRawPointer?, _ json: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    guard let pointer else { return writeError("{}", json, capacity) }
    let snapshot = preparedHandle(pointer).context.status.snapshot()
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(snapshot)) ?? Data("{}".utf8)
    return writeError(String(decoding: data, as: UTF8.self), json, capacity)
}

@_cdecl("fe_prepared_destroy")
public func fePreparedDestroy(_ pointer: UnsafeMutableRawPointer?) {
    guard let pointer else { return }
    preparedHandle(pointer).context.requestCancel()
    Unmanaged<PreparedFrameEngineHandle>.fromOpaque(pointer).release()
}
