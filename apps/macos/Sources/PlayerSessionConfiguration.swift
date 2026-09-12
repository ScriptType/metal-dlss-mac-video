import Foundation
import Darwin

/// Explicit app-preference isolation for an interactive, test-owned session.
/// Resolving this configuration precedes AppKit and diagnostic CLI dispatch.
struct PlayerSessionConfiguration {
    let isTransient: Bool
    let cacheDirectory: URL?

    private init(isTransient: Bool, cacheDirectory: URL?) {
        self.isTransient = isTransient
        self.cacheDirectory = cacheDirectory
    }

    enum Failure: Error, CustomStringConvertible {
        case invalidTransientValue
        case conflictingEnvironment(String)
        case diagnosticArgument(String)
        case freshAbsoluteCacheRequired
        case cacheCreationFailed(Int32)

        var description: String {
            switch self {
            case .invalidTransientValue:
                return "HDRPLAYER_TRANSIENT_SESSION must be absent, 0, or 1; malformed isolation requests are rejected."
            case .conflictingEnvironment(let name):
                return "HDRPLAYER_TRANSIENT_SESSION cannot be combined with \(name)."
            case .diagnosticArgument(let name):
                return "HDRPLAYER_TRANSIENT_SESSION cannot forward diagnostic argument \(name)."
            case .freshAbsoluteCacheRequired:
                return "HDRPLAYER_TRANSIENT_SESSION requires HDRPLAYER_CACHE_DIRECTORY to name a fresh absolute directory with an existing parent."
            case .cacheCreationFailed(let code):
                return "Cannot exclusively create the transient cache directory (errno \(code)); existing entries are never reused or removed."
            }
        }
    }

    static func resolve(environment: [String: String], arguments: [String]) throws -> Self {
        let flag = environment["HDRPLAYER_TRANSIENT_SESSION"]
        guard flag == nil || flag == "0" || flag == "1" else { throw Failure.invalidTransientValue }
        guard flag == "1" else {
            return Self(isTransient: false, cacheDirectory: nil)
        }
        // Presence is a conflict, even if an inherited diagnostic value is empty
        // or "0". The ordinary floating route remains available for real input.
        let conflict = environment.keys.sorted().first { name in
            name.hasPrefix("HDRPLAYER_UI_SMOKE_") ||
            (name.hasPrefix("HDRPLAYER_FLOATING_") && name != "HDRPLAYER_FLOATING_VIDEO") ||
            name == "HDRPLAYER_ENABLE_PIP" || name == "HDRPLAYER_PIP" ||
            name.hasPrefix("HDRPLAYER_PIP_") || name.hasPrefix("HDRPLAYER_SYSTEM_PIP_")
        }
        if let conflict { throw Failure.conflictingEnvironment(conflict) }
        let diagnostic = Set(["--headless", "--capture-dir", "--capture-every", "--headroom", "--report", "--frames", "--exit-after-playback"])
        if let argument = arguments.first(where: {
            diagnostic.contains(String($0.split(separator: "=", maxSplits: 1).first ?? Substring($0)))
        }) { throw Failure.diagnosticArgument(argument) }
        guard let path = environment["HDRPLAYER_CACHE_DIRECTORY"], path.hasPrefix("/"),
              !path.utf8.contains(0) else { throw Failure.freshAbsoluteCacheRequired }
        let cache = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        // mkdir is the exclusive claim; do not check then create, accept an
        // existing directory/symlink, create parents, or clean up on failure.
        let result = cache.path.withCString { Darwin.mkdir($0, mode_t(0o700)) }
        guard result == 0 else { throw Failure.cacheCreationFailed(errno) }
        return Self(isTransient: true, cacheDirectory: cache)
    }
}

/// The persistence factory is deliberately lazy: transient construction never
/// creates, reads, resets, or writes any UserDefaults object or suite.
@MainActor
final class PlayerSessionPreferences {
    typealias PersistentBacking = (values: [String: Any], write: ([String: Any]) -> Void)
    private let write: (([String: Any]) -> Void)?
    private(set) var values: [String: Any]

    init(transient: Bool, persistent: () -> PersistentBacking) {
        if transient {
            values = ["enabled": false, "muted": true]
            write = nil
        } else {
            let backing = persistent()
            values = backing.values
            write = backing.write
        }
    }

    func replace(_ values: [String: Any]) {
        self.values = values
        write?(values)
    }
}
