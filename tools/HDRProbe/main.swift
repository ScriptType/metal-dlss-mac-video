import Foundation
import FrameEngine

@main
struct HDRProbeCommand {
    static func main() async throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.isEmpty {
            print(String(decoding: try encoder.encode(GPUProbe.run()), as: UTF8.self))
        } else if arguments.count == 2, arguments[0] == "--video" {
            let report = try await VideoProbe.run(url: URL(fileURLWithPath: arguments[1]))
            print(String(decoding: try encoder.encode(report), as: UTF8.self))
        } else {
            FileHandle.standardError.write(Data("Usage: hdr-probe [--video FILE]\n".utf8))
            exit(64)
        }
    }
}
