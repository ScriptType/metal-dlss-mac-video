// Public Accessibility API probe for a running system PiP owner. Default mode
// is read-only. It never launches an application, requests consent, changes an
// OS preference, reads unrelated windows, or invokes an AVKit delegate itself.
import AppKit
import ApplicationServices
import CryptoKit
import Foundation

private struct Options {
    var owner: pid_t?, bundle: String?, node: String?, token: String?, output: String?
    var press = false
    var size: CGSize?
    var actionRequested: Bool { press || size != nil }

    static let usage = """
    system-pip-accessibility [--owner-pid PID --owner-bundle ID] [--output FILE]
    system-pip-accessibility --owner-pid PID --owner-bundle ID --node PATH --token SHA256 --press [--output FILE]
    system-pip-accessibility --owner-pid PID --owner-bundle ID --node PATH --token SHA256 --resize WIDTHxHEIGHT [--output FILE]

    Default: inspect running Apple PiP owners; no action or consent prompt.
    Use a node path/token from a fresh inspection. Actions re-check owner,
    identity, labels, bounds and supported AX actions immediately before use.
    Resize requires a window with settable AXSize. No action is auto-retried.
    """

    init(_ values: [String]) throws {
        var index = 0
        func invalid(_ message: String) -> NSError {
            NSError(domain: "PiP.AX.Arguments", code: 2, userInfo: [NSLocalizedDescriptionKey: message])
        }
        while index < values.count {
            let name = values[index]; index += 1
            if name == "--press" { press = true; continue }
            guard ["--owner-pid", "--owner-bundle", "--node", "--token", "--resize", "--output"].contains(name), index < values.count else {
                throw invalid("Unknown or incomplete argument: \(name)")
            }
            let value = values[index]; index += 1
            switch name {
            case "--owner-pid":
                guard let pid = Int32(value), pid > 0 else { throw invalid("Owner PID must be a positive Int32") }
                owner = pid
            case "--owner-bundle": bundle = value
            case "--node": node = value
            case "--token": token = value
            case "--output": output = value
            case "--resize":
                let parts = value.split(separator: "x")
                guard parts.count == 2, let width = Double(parts[0]), let height = Double(parts[1]),
                      width.isFinite, height.isFinite, (64...2048).contains(width), (36...2048).contains(height) else {
                    throw invalid("Resize must be finite WIDTHxHEIGHT within 64...2048 by 36...2048")
                }
                size = CGSize(width: width, height: height)
            default: break
            }
        }
        guard (owner == nil) == (bundle == nil) else { throw invalid("Owner PID and bundle identifier must be supplied together") }
        guard !(press && size != nil) else { throw invalid("Choose exactly one action per invocation") }
        if actionRequested {
            guard owner != nil, let node, !node.isEmpty, let token, token.count == 64,
                  token.allSatisfy({ $0.isHexDigit }) else {
                throw invalid("An action requires explicit owner PID/bundle, node path and fresh SHA256 token")
            }
        } else if node != nil || token != nil { throw invalid("Node/token are only used with an explicit action") }
    }
}

private struct AXNode {
    let element: AXUIElement
    let path: String
    let token: String
    let record: [String: Any]
}

@MainActor
private final class PiPInspector {
    let deadline = Date().addingTimeInterval(5)
    var nodes: [String: AXNode] = [:]
    var visited: [AXUIElement] = []
    var errors: [String: Int] = [:]
    var limited = false
    var windowCount = 0
    var ownerPID: pid_t = 0
    var ownerIdentity: [String: Any] = [:]

    static func candidate(_ application: NSRunningApplication) -> Bool {
        // Discovery is based on the owner's bundle, never a guessed control
        // label or content/title from another application's window.
        let identifier = (application.bundleIdentifier ?? "").lowercased()
        let component = application.bundleURL?.lastPathComponent.lowercased() ?? ""
        return identifier.hasPrefix("com.apple.") &&
            (identifier.contains("pipagent") || identifier.contains("pictureinpicture") || component == "pipagent.app")
    }

    func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        guard Date() < deadline else { limited = true; return nil }
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if status != .success {
            let key = "\(name):\(status.rawValue)"; errors[key, default: 0] += 1
            return nil
        }
        return value
    }
    func text(_ element: AXUIElement, _ name: String) -> String? {
        (attribute(element, name) as? String).map { String($0.prefix(256)) }
    }
    func actions(_ element: AXUIElement) -> [String] {
        guard Date() < deadline else { limited = true; return [] }
        var value: CFArray?
        let status = AXUIElementCopyActionNames(element, &value)
        if status != .success { errors["actions:\(status.rawValue)", default: 0] += 1 }
        return (value as? [String] ?? []).sorted()
    }
    func settable(_ element: AXUIElement, _ name: String) -> Bool {
        guard Date() < deadline else { limited = true; return false }
        var result = DarwinBoolean(false)
        let status = AXUIElementIsAttributeSettable(element, name as CFString, &result)
        if status != .success { errors["settable-\(name):\(status.rawValue)", default: 0] += 1 }
        return status == .success && result.boolValue
    }
    func pair(_ element: AXUIElement, _ attributeName: String, type: AXValueType) -> [Double]? {
        guard let object = attribute(element, attributeName), CFGetTypeID(object) == AXValueGetTypeID() else { return nil }
        let value = object as! AXValue
        guard AXValueGetType(value) == type else { return nil }
        if type == .cgPoint {
            var point = CGPoint.zero
            return AXValueGetValue(value, .cgPoint, &point) ? [point.x, point.y] : nil
        }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? [size.width, size.height] : nil
    }
    func record(_ element: AXUIElement, path: String) -> AXNode? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success, pid == ownerPID,
              let role = text(element, kAXRoleAttribute) else { return nil }
        var value: [String: Any] = ["path": path, "role": role, "actions": actions(element),
            "positionSettable": settable(element, kAXPositionAttribute), "sizeSettable": settable(element, kAXSizeAttribute)]
        value["subrole"] = text(element, kAXSubroleAttribute)
        value["identifier"] = text(element, kAXIdentifierAttribute)
        value["enabled"] = attribute(element, kAXEnabledAttribute) as? Bool
        value["position"] = pair(element, kAXPositionAttribute, type: .cgPoint)
        value["size"] = pair(element, kAXSizeAttribute, type: .cgSize)
        // Only actionable controls carry labels. Window titles, source/media
        // names, static text, captions, text values and document URLs are omitted.
        let labeledRoles = [kAXButtonRole, kAXCheckBoxRole, kAXRadioButtonRole, kAXSliderRole,
                            kAXMenuButtonRole, kAXPopUpButtonRole, kAXDisclosureTriangleRole]
        if labeledRoles.contains(role) {
            value["title"] = text(element, kAXTitleAttribute)
            value["description"] = text(element, kAXDescriptionAttribute)
            value["help"] = text(element, kAXHelpAttribute)
        }
        let identity = ownerIdentity.merging(["node": value]) { _, new in new }
        guard let data = try? JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys]) else { return nil }
        let token = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        value["matchToken"] = token
        return AXNode(element: element, path: path, token: token, record: value)
    }
    func walk(_ element: AXUIElement, path: String, depth: Int) {
        guard nodes.count < 256, depth <= 12, Date() < deadline else { limited = true; return }
        guard !visited.contains(where: { CFEqual($0, element) }) else { return }
        visited.append(element)
        guard let node = record(element, path: path) else { return }
        nodes[path] = node
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        if children.count > 64 { limited = true }
        for (index, child) in children.prefix(64).enumerated() { walk(child, path: "\(path)/\(index)", depth: depth + 1) }
    }
    func inspect(_ application: NSRunningApplication) -> [String: Any] {
        ownerPID = application.processIdentifier
        ownerIdentity = ["pid": ownerPID, "bundleIdentifier": application.bundleIdentifier ?? "",
                         "launchTime": application.launchDate?.timeIntervalSince1970 ?? 0]
        let element = AXUIElementCreateApplication(ownerPID)
        _ = AXUIElementSetMessagingTimeout(element, 0.25)
        let windows = attribute(element, kAXWindowsAttribute) as? [AXUIElement] ?? []
        windowCount = windows.count
        if windows.count > 4 { limited = true }
        for (index, window) in windows.prefix(4).enumerated() { walk(window, path: "w\(index)", depth: 0) }
        return ownerIdentity.merging(["windowCount": windows.count, "nodes": nodes.values.sorted { $0.path < $1.path }.map(\.record),
            "attributeErrors": errors, "inspectionTruncated": limited, "omittedWindowTitlesAndStaticContent": true]) { _, new in new }
    }
}

@main
private struct SystemPiPAccessibility {
    @MainActor static func main() {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") { print(Options.usage); return }
        var output: String?
        var result: [String: Any] = ["schemaVersion": 1, "recordedUTC": ISO8601DateFormatter().string(from: Date()),
            "hostSeconds": ProcessInfo.processInfo.systemUptime, "actionsPerformed": false,
            "requestsPermission": false, "changesOSPreferences": false, "launchesApplications": false,
            "scope": "System PiP owner Accessibility inspection/actions; native callback, playback and presentation effects require separate observations"]
        var exitStatus: Int32 = 0
        do {
            let options = try Options(arguments); output = options.output
            result["actionRequested"] = options.actionRequested
            let trusted = AXIsProcessTrusted()
            result["accessibilityTrusted"] = trusted
            guard trusted else { throw failure("Existing Accessibility permission is unavailable; no prompt requested", code: 3) }
            let applications = NSWorkspace.shared.runningApplications.filter(PiPInspector.candidate)
            let selected = applications.filter { options.owner == nil ||
                ($0.processIdentifier == options.owner && $0.bundleIdentifier == options.bundle) }
            result["candidateOwners"] = applications.map { ["pid": $0.processIdentifier, "bundleIdentifier": $0.bundleIdentifier ?? ""] as [String: Any] }
            if options.owner != nil && selected.isEmpty {
                throw failure("The explicit PID/bundle does not match a running discovered Apple PiP owner", code: 4)
            }
            var owners: [[String: Any]] = []
            for application in selected.prefix(4) {
                let inspector = PiPInspector()
                owners.append(inspector.inspect(application))
                guard options.actionRequested else { continue }
                guard inspector.windowCount == 1 else {
                    throw failure("Action requires exactly one window in the matched PiP owner; selection is ambiguous", code: 5)
                }
                guard let path = options.node, let prior = inspector.nodes[path],
                      let current = inspector.record(prior.element, path: path), current.token == options.token else {
                    throw failure("Target no longer matches the supplied inspection token; inspect again before acting", code: 5)
                }
                result["matchedTarget"] = current.record
                var status: AXError
                if options.press {
                    guard (current.record["actions"] as? [String] ?? []).contains(kAXPressAction),
                          current.record["enabled"] as? Bool != false else {
                        throw failure("The matched control does not currently expose enabled AXPress", code: 6)
                    }
                    result["action"] = "AXPress"
                    result["actionStartedHostSeconds"] = ProcessInfo.processInfo.systemUptime
                    status = AXUIElementPerformAction(current.element, kAXPressAction as CFString)
                } else if var size = options.size {
                    guard current.record["role"] as? String == kAXWindowRole, current.record["sizeSettable"] as? Bool == true,
                          let value = AXValueCreate(.cgSize, &size) else {
                        throw failure("The matched window does not expose a settable AXSize", code: 6)
                    }
                    result["action"] = "set-AXSize"; result["requestedSize"] = [size.width, size.height]
                    result["actionStartedHostSeconds"] = ProcessInfo.processInfo.systemUptime
                    status = AXUIElementSetAttributeValue(current.element, kAXSizeAttribute as CFString, value)
                } else { continue }
                result["actionsPerformed"] = true; result["actionAXStatus"] = status.rawValue
                result["actionReturnedSuccess"] = status == .success
                result["actionHostSeconds"] = ProcessInfo.processInfo.systemUptime
                result["afterActionTarget"] = inspector.record(current.element, path: path)?.record
                if status != .success {
                    // CannotComplete may mean the owner is still handling it.
                    // Never repeat a potentially delivered toggle automatically.
                    throw failure("AX action returned \(status.rawValue); effect is unverified and was not retried", code: 6)
                }
            }
            result["owners"] = owners
            result["reason"] = selected.isEmpty ? "No running Apple PiP owner discovered; no action was taken" : "Scoped inspection complete"
        } catch {
            let error = error as NSError
            exitStatus = Int32(error.code); result["error"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            if let output {
                let url = URL(fileURLWithPath: output)
                do {
                    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } catch { FileHandle.standardError.write(Data("Cannot write report: \(error)\n".utf8)); exitStatus = 7 }
            }
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
        } else { exitStatus = 7 }
        exit(exitStatus)
    }
    static func failure(_ message: String, code: Int) -> NSError {
        NSError(domain: "PiP.AX", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
