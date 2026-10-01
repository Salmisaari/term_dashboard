// Root-owned launchd service. The socket API never accepts commands or paths.
import Foundation
import IOKit.pwr_mgt
import IOKit.ps
import Darwin

let awakeSocket = "/var/run/com.td.awake/control.sock"
let awakeJournal = "/var/db/com.td.awake.json"
let awakeDurations: [String: Double] = ["1h": 3600, "4h": 14400, "24h": 86400]

struct AwakeSession: Codable {
    let state: String
    let end_ts: Double
}
struct AwakePower {
    let battery: Int?
    let onAC: Bool
    let critical: Bool
}
enum AwakeFailure: Error, LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
protocol AwakeSystem {
    func disabled() throws -> Bool
    func setDisabled(_ disabled: Bool) throws
    func power() throws -> AwakePower
    func save(_ session: AwakeSession) throws
    func clear() throws
}

// This state machine is exercised with a fake system; the production adapter
// below is the only component that can change macOS power settings.
final class AwakeController {
    let system: AwakeSystem
    var session: AwakeSession?
    var restoring = false
    var reason = "Awake is off."
    var failure = ""
    init(system: AwakeSystem, recovering: Bool = false) {
        self.system = system
        self.restoring = recovering
    }
    func stop(_ why: String) throws {
        guard session != nil || restoring else { reason = why; return }
        restoring = true
        try system.setDisabled(false)
        guard try !system.disabled() else { throw AwakeFailure.message("macOS has not restored sleep yet.") }
        try system.clear()
        session = nil; restoring = false; failure = ""; reason = why
    }
    func tick(now: Double) {
        do {
            if restoring { try stop("Sleep restored after helper restart or interrupted change."); return }
            guard let active = session else { return }
            if now >= active.end_ts { try stop("Awake timer finished."); return }
            let power = try system.power()
            if power.critical { try stop("Awake stopped: Mac temperature is critical."); return }
            if !power.onAC, let battery = power.battery, battery <= 10 {
                try stop("Awake stopped: battery is at or below 10%."); return
            }
            if try !system.disabled() { try stop("Awake stopped: system sleep setting changed outside TD.") }
        } catch {
            failure = error.localizedDescription
            // Unreadable power state must not leave an unbounded battery session.
            if session != nil || restoring {
                do { try stop("Awake stopped: " + failure) }
                catch { restoring = true; failure = error.localizedDescription }
            }
        }
    }
    func start(_ duration: String, now: Double) throws {
        guard let seconds = awakeDurations[duration] else { throw AwakeFailure.message("Choose 1h, 4h, or 24h.") }
        guard !restoring else { throw AwakeFailure.message("Sleep restoration is pending. Try Off again.") }
        let power = try system.power()
        guard !power.critical else { throw AwakeFailure.message("Mac temperature is critical; awake was not started.") }
        if !power.onAC, let battery = power.battery, battery <= 10 {
            throw AwakeFailure.message("Charge above 10% or connect power before starting Awake.")
        }
        if session == nil, try system.disabled() {
            throw AwakeFailure.message("Sleep is already disabled outside TD. Turn off the other awake app or setting first.")
        }
        let next = AwakeSession(state: duration, end_ts: now + seconds)
        // Write ahead: a crash after changing pmset must still restore sleep.
        try system.save(next)
        session = next
        do {
            try system.setDisabled(true)
            guard try system.disabled() else { throw AwakeFailure.message("macOS did not enable closed-lid protection.") }
            failure = ""; reason = "Closed-lid awake · stops at 10% battery."
        } catch {
            let original = error
            restoring = true
            do { try stop("Awake could not start.") } catch { failure = error.localizedDescription }
            throw original
        }
    }
    func status(now: Double) -> [String: Any] {
        tick(now: now)
        return ["state": session?.state ?? "off", "end_ts": session?.end_ts ?? 0,
                "backend": "native", "helper_installed": true,
                "closed_lid": session != nil && !restoring && failure.isEmpty,
                "restoring": restoring, "message": reason, "error": failure,
                "battery_cutoff": 10]
    }
    func handle(_ request: [String: Any], now: Double) -> [String: Any] {
        tick(now: now)
        do {
            switch request["action"] as? String {
            case "status": break
            case "off": try stop("Awake is off. Normal sleep restored.")
            case "start": try start(request["duration"] as? String ?? "", now: now)
            default: throw AwakeFailure.message("Unknown awake action.")
            }
            return status(now: now)
        } catch {
            var result = status(now: now)
            result["error"] = error.localizedDescription
            return result
        }
    }
}

final class MacAwakeSystem: AwakeSystem {
    func pmset(_ args: [String]) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        try process.run()
        let deadline = Date().addingTimeInterval(3)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { process.terminate(); throw AwakeFailure.message("macOS power settings timed out.") }
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw AwakeFailure.message("Could not change macOS power settings: " + output.prefix(250)) }
        return output
    }
    func disabled() throws -> Bool {
        // Read the effective kernel flag directly. `pmset -g` also enumerates
        // every app's sleep assertions and can stall on unrelated app IPC.
        let root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"))
        guard root != 0 else { throw AwakeFailure.message("Could not read macOS sleep state.") }
        defer { IOObjectRelease(root) }
        guard let value = IORegistryEntryCreateCFProperty(root, "SleepDisabled" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() else {
            return false // An unset kernel flag means sleep is enabled.
        }
        guard CFGetTypeID(value) == CFBooleanGetTypeID(), let disabled = value as? Bool else {
            throw AwakeFailure.message("Unrecognized macOS sleep state.")
        }
        return disabled
    }
    func setDisabled(_ disabled: Bool) throws { _ = try pmset(["-a", "disablesleep", disabled ? "1" : "0"]) }
    func power() throws -> AwakePower {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else {
            throw AwakeFailure.message("Could not read battery state.")
        }
        var battery: Int?
        var onAC = true
        for source in sources {
            guard let data = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else {
                throw AwakeFailure.message("Could not read battery details.")
            }
            guard data[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
            guard let current = data[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = data[kIOPSMaxCapacityKey] as? Int, maximum > 0,
                  let sourceState = data[kIOPSPowerSourceStateKey] as? String else {
                throw AwakeFailure.message("Could not read battery charge.")
            }
            battery = current * 100 / maximum
            onAC = sourceState == kIOPSACPowerValue
        }
        guard battery != nil else { throw AwakeFailure.message("Internal battery state is unavailable; closed-lid awake was stopped.") }
        return AwakePower(battery: battery, onAC: onAC, critical: ProcessInfo.processInfo.thermalState == .critical)
    }
    func save(_ session: AwakeSession) throws {
        try JSONEncoder().encode(session).write(to: URL(fileURLWithPath: awakeJournal), options: .atomic)
        guard chmod(awakeJournal, 0o600) == 0 else { throw AwakeFailure.message("Could not protect awake recovery state.") }
    }
    func clear() throws {
        if FileManager.default.fileExists(atPath: awakeJournal) { try FileManager.default.removeItem(atPath: awakeJournal) }
    }
}

var awakeTerminating = false
func awakeSignal(_ number: Int32) { awakeTerminating = true }

func serveAwake(owner: uid_t) throws {
    guard getuid() == 0, owner > 0 else { throw AwakeFailure.message("The awake helper must run through its installed launchd service.") }
    signal(SIGTERM, awakeSignal); signal(SIGINT, awakeSignal); signal(SIGPIPE, SIG_IGN)
    let system = MacAwakeSystem()
    let controller = AwakeController(system: system, recovering: FileManager.default.fileExists(atPath: awakeJournal))
    controller.tick(now: Date().timeIntervalSince1970)
    let directory = (awakeSocket as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    guard chmod(directory, 0o755) == 0 else { throw AwakeFailure.message("Cannot open awake control directory.") }
    unlink(awakeSocket)
    let listener = socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw AwakeFailure.message("Cannot create awake socket.") }
    defer { close(listener); unlink(awakeSocket); try? controller.stop("Awake helper stopped.") }
    var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
    let pathBytes = Array(awakeSocket.utf8CString)
    withUnsafeMutableBytes(of: &address.sun_path) { bytes in bytes.copyBytes(from: pathBytes.map { UInt8(bitPattern: $0) }) }
    let size = socklen_t(MemoryLayout<sockaddr_un>.size)
    address.sun_len = UInt8(size)
    let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, size) } }
    guard bound == 0, chmod(awakeSocket, 0o666) == 0, listen(listener, 8) == 0 else {
        throw AwakeFailure.message("Cannot listen on awake socket.")
    }
    while !awakeTerminating {
        controller.tick(now: Date().timeIntervalSince1970)
        var event = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 1000) > 0 else { continue }
        let client = accept(listener, nil, nil)
        guard client >= 0 else { continue }
        defer { close(client) }
        var user: uid_t = 0; var group: gid_t = 0
        guard getpeereid(client, &user, &group) == 0, user == owner || user == 0 else { continue }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        // Read at most 1024 bytes within one absolute deadline (not per byte).
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = Date().addingTimeInterval(2)
        while data.count < 1024 && Date() < deadline && !data.contains(10) {
            let count = recv(client, &buffer, 1024 - data.count, 0)
            if count <= 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        let reply: [String: Any]
        if data.count < 1024, data.last == 10,
           let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            reply = controller.handle(request, now: Date().timeIntervalSince1970)
        } else { reply = ["error": "Invalid awake request."] }
        var output = try JSONSerialization.data(withJSONObject: reply); output.append(10)
        output.withUnsafeBytes { bytes in
            var sent = 0
            while sent < bytes.count {
                let count = send(client, bytes.baseAddress!.advanced(by: sent), bytes.count - sent, 0)
                if count <= 0 { break }; sent += count
            }
        }
    }
}

// Tests compile the definitions above with an isolated adapter and test entry point.
// A root service accepts no path/environment overrides.
if CommandLine.arguments == [CommandLine.arguments[0], "--version"] {
    print("TD awake helper 1.0")
} else if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--daemon",
          let owner = uid_t(CommandLine.arguments[2]) {
    do { try serveAwake(owner: owner) }
    catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
} else {
    fputs("Usage: td-awake --daemon OWNER_UID\n", stderr); exit(1)
}
