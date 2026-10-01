var checks = 0
func check(_ ok: @autoclosure () -> Bool, _ message: String) {
    checks += 1
    if !ok() { fputs("FAIL: " + message + "\n", stderr); exit(1) }
}
final class FakeAwakeSystem: AwakeSystem {
    var sleepDisabled = false
    var snapshot = AwakePower(battery: 80, onAC: true, critical: false)
    var journal: AwakeSession?
    var writes: [Bool] = []
    var failSet = false
    var ignoreSet = false
    var failSave = false
    var failPower = false
    func disabled() throws -> Bool { sleepDisabled }
    func setDisabled(_ value: Bool) throws {
        writes.append(value)
        if failSet { throw AwakeFailure.message("pmset failure") }
        if !ignoreSet { sleepDisabled = value }
    }
    func power() throws -> AwakePower {
        if failPower { throw AwakeFailure.message("battery unavailable") }
        return snapshot
    }
    func save(_ session: AwakeSession) throws {
        if failSave { throw AwakeFailure.message("disk failure") }
        journal = session
    }
    func clear() throws { journal = nil }
}
let hardware = FakeAwakeSystem()
let controller = AwakeController(system: hardware)
func start(_ duration: String = "1h", now: Double = 100) -> [String: Any] {
    controller.handle(["action": "start", "duration": duration], now: now)
}
check(start()["closed_lid"] as? Bool == true, "starting verifies protection")
check(hardware.journal?.end_ts == 3700, "deadline journaled")
controller.tick(now: 3699)
check(hardware.sleepDisabled, "alive before expiry")
controller.tick(now: 3700)
check(!hardware.sleepDisabled && hardware.journal == nil, "expiry restores and clears journal")

_ = start()
check(start("4h", now: 200)["end_ts"] as? Double == 14600, "new duration replaces old deadline")
hardware.snapshot = AwakePower(battery: 70, onAC: false, critical: false)
controller.tick(now: 300)
check(hardware.sleepDisabled, "unplugging continues on battery")
hardware.snapshot = AwakePower(battery: 10, onAC: false, critical: false)
controller.tick(now: 301)
check(!hardware.sleepDisabled && controller.session == nil, "low battery restores sleep")
check((start()["error"] as? String ?? "") != "", "cannot start at battery cutoff")
hardware.snapshot = AwakePower(battery: 3, onAC: true, critical: false)
check(start()["closed_lid"] as? Bool == true, "low charge allowed on AC")
hardware.snapshot = AwakePower(battery: 3, onAC: false, critical: false)
controller.tick(now: 101)
check(!hardware.sleepDisabled, "unplugging below cutoff restores sleep")

hardware.snapshot = AwakePower(battery: 80, onAC: true, critical: false)
_ = start()
hardware.snapshot = AwakePower(battery: 80, onAC: true, critical: true)
controller.tick(now: 101)
check(!hardware.sleepDisabled, "thermal emergency restores sleep")
check((start()["error"] as? String ?? "") != "", "thermal emergency blocks start")
hardware.snapshot = AwakePower(battery: 80, onAC: true, critical: false)
_ = start()
hardware.failPower = true
controller.tick(now: 101)
check(!hardware.sleepDisabled, "unreadable battery fails closed")
hardware.failPower = false

hardware.sleepDisabled = true
let writesBefore = hardware.writes.count
check((start()["error"] as? String ?? "") != "", "refuses externally disabled sleep")
_ = controller.handle(["action": "off"], now: 101)
check(hardware.sleepDisabled && hardware.writes.count == writesBefore, "off leaves externally owned sleep unchanged")
hardware.sleepDisabled = false
hardware.failSave = true
check((start()["error"] as? String ?? "") != "", "journal write failure reported")
check(!hardware.sleepDisabled && controller.session == nil, "never changes sleep without journal")
hardware.failSave = false
hardware.ignoreSet = true
check((start()["error"] as? String ?? "") != "", "successful process exit alone is not protection")
check(!hardware.sleepDisabled && controller.session == nil, "ineffective setting rolled back")
hardware.ignoreSet = false

hardware.failSet = true
let failedStart = start()
check(!(failedStart["error"] as? String ?? "").isEmpty && failedStart["closed_lid"] as? Bool == false, "failed setting never reports successful protection")
check(hardware.journal != nil, "failed setting retains recovery until restore succeeds")
hardware.failSet = false
controller.tick(now: 101)
check(!hardware.sleepDisabled && hardware.journal == nil, "failed start eventually restores")

_ = start()
hardware.sleepDisabled = false
controller.tick(now: 101)
check(controller.session == nil && hardware.journal == nil, "external sleep-setting change invalidates active protection")

_ = start()
hardware.failSet = true
let failedStop = controller.handle(["action": "off"], now: 101)
check(failedStop["restoring"] as? Bool == true, "failed stop is visible")
check(failedStop["closed_lid"] as? Bool == false, "failed restoration never reports healthy")
check(hardware.journal != nil, "failed restore preserves recovery journal")
hardware.failSet = false
controller.tick(now: 102)
check(!hardware.sleepDisabled && hardware.journal == nil, "restore is retried")

_ = start()
let restarted = AwakeController(system: hardware, recovering: hardware.journal != nil)
restarted.tick(now: 200)
check(!hardware.sleepDisabled && hardware.journal == nil, "crash/reboot restores instead of silently resuming")
for request: [String: Any] in [["action": "start", "duration": "forever"], ["action": "shell", "command": "id"], ["action": "start", "duration": 3600]] {
    check((restarted.handle(request, now: 200)["error"] as? String ?? "") != "", "invalid request rejected")
    check(!hardware.sleepDisabled, "invalid request has no power effects")
}
// Exercise real battery reading and pmset parsing without changing system state.
let live = MacAwakeSystem()
do {
    _ = try live.disabled()
    let power = try live.power()
    check(power.battery == nil || (0...100).contains(power.battery!), "real battery adapter returns valid percentage")
} catch { fputs("Read-only Mac adapter check failed: \(error)\n", stderr); exit(1) }
print("\(checks) awake helper checks passed.")
