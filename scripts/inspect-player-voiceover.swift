// Read-only capability probe. No feature activation, cursor movement, preference
// writes, application launch, or prompting for Accessibility/Automation access.
import AppKit
import ApplicationServices
import Carbon

func fourCC(_ text: String) -> OSType {
    text.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
}

func property(_ code: String, of container: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
    let record = NSAppleEventDescriptor.record()
    record.setDescriptor(NSAppleEventDescriptor(typeCode: cProperty), forKeyword: AEKeyword(keyAEDesiredClass))
    record.setDescriptor(NSAppleEventDescriptor(enumCode: OSType(formPropertyID)), forKeyword: AEKeyword(keyAEKeyForm))
    record.setDescriptor(NSAppleEventDescriptor(typeCode: fourCC(code)), forKeyword: AEKeyword(keyAEKeyData))
    record.setDescriptor(container, forKeyword: AEKeyword(keyAEContainer))
    return record.coerce(toDescriptorType: typeObjectSpecifier)!
}

func read(_ object: NSAppleEventDescriptor, target: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor? {
    let event = NSAppleEventDescriptor(eventClass: kAECoreSuite, eventID: kAEGetData,
        targetDescriptor: target, returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    event.setParam(object, forKeyword: keyDirectObject)
    let noConsentPrompt = NSAppleEventDescriptor.SendOptions(rawValue: UInt(kAEDoNotPromptForUserConsent))
    let reply = try event.sendEvent(options: [.waitForReply, .neverInteract, noConsentPrompt], timeout: 2)
    if let error = reply.paramDescriptor(forKeyword: keyErrorNumber), error.int32Value != 0 {
        throw NSError(domain: NSOSStatusErrorDomain, code: Int(error.int32Value),
            userInfo: [NSLocalizedDescriptionKey: reply.paramDescriptor(forKeyword: keyErrorString)?.stringValue ?? "VoiceOver rejected read access"])
    }
    return reply.paramDescriptor(forKeyword: keyDirectObject)
}

let arguments = CommandLine.arguments.dropFirst()
let wantsPhrase = arguments.contains("--read-current-phrase")
let playerPID = arguments.firstIndex(of: "--player-pid").flatMap { index in
    let next = arguments.index(after: index)
    return next < arguments.endIndex ? Int32(arguments[next]) : nil
}
let workspace = NSWorkspace.shared
let application = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.VoiceOver").first
var report: [String: Any] = ["version": 1, "voiceOverEnabled": workspace.isVoiceOverEnabled,
    "voiceOverRunning": application != nil, "accessibilityTrusted": AXIsProcessTrusted(),
    "changesOSPreferences": false, "requestsNewPermission": false, "movesAccessibilityFocus": false,
    "phraseReadRequested": wantsPhrase, "actualPhraseObserved": false,
    "speechQualification": "unverified; phrase text does not prove audible output"]

if let application {
    // Address the existing process directly: a race with exit cannot launch VO.
    let target = NSAppleEventDescriptor(processIdentifier: application.processIdentifier)
    let permission = AEDeterminePermissionToAutomateTarget(target.aeDesc, kAECoreSuite, kAEGetData, false)
    report["automationReadStatus"] = permission
    if !workspace.isVoiceOverEnabled {
        report["reason"] = "VoiceOver is disabled; no screen-reader output was requested."
    } else if permission != noErr {
        report["reason"] = "Existing Automation access is unavailable; no permission prompt was requested."
    } else if !wantsPhrase {
        report["reason"] = "Read access exists. Phrase observation requires --read-current-phrase --player-pid PID and a foreground player."
    } else if playerPID == nil || workspace.frontmostApplication?.processIdentifier != playerPID {
        report["reason"] = "Phrase observation requires the specified player to be foreground."
    } else {
        do {
            report["lastPhrase"] = try read(property("lptx", of: property("lapr")), target: target)?.stringValue ?? ""
            report["cursorText"] = try read(property("votx", of: property("vocu")), target: target)?.stringValue ?? ""
            report["captionPanelEnabled"] = try read(property("cwon", of: property("capa")), target: target)?.booleanValue ?? false
            report["actualPhraseObserved"] = !(report["lastPhrase"] as? String ?? "").isEmpty
            report["reason"] = "Read existing VoiceOver output. This probe did not navigate or request an announcement."
        } catch {
            report["reason"] = "VoiceOver scripting read failed. Its separate AppleScript control preference may be disabled."
            report["readError"] = error.localizedDescription
        }
    }
} else {
    report["automationReadStatus"] = NSNull()
    report["reason"] = "VoiceOver is not running; no application was launched and no announcement was observed."
}
let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
FileHandle.standardOutput.write(data)
FileHandle.standardOutput.write(Data([0x0A]))
