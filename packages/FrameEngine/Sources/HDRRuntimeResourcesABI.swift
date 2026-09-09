import CFrameEngine
import Foundation

@_cdecl("fe_runtime_configure")
public func feRuntimeConfigure(_ json: UnsafePointer<CChar>?, _ error: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int32 {
    do {
        guard let json else { throw FrameEngineError.invalid("Missing runtime resource policy") }
        let policy = try JSONDecoder().decode(HDRRuntimeResourcePolicy.self, from: Data(String(cString: json).utf8))
        try HDRRuntimeResources.shared.configure(policy)
        _ = writeError("", error, capacity)
        return Int32(FE_ACCEPTED.rawValue)
    } catch let failure {
        _ = writeError(failure.localizedDescription, error, capacity)
        return Int32(FE_FAILED.rawValue)
    }
}

@_cdecl("fe_runtime_resources_json")
public func feRuntimeResourcesJSON(_ json: UnsafeMutablePointer<CChar>?, _ capacity: Int) -> Int {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let data = (try? encoder.encode(HDRRuntimeResources.shared.snapshot())) ?? Data("{}".utf8)
    return writeError(String(decoding: data, as: UTF8.self), json, capacity)
}
