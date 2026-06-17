import XCTest
@testable import PowerSleuth

final class WakeParserTests: XCTestCase {

    // Real pmset -g log line shapes (timestamp is the first 25 chars).
    private let log = """
    2026-06-16 22:28:56 -0700 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB.SPMI0Sw3IRQ nub-spmi0.0x02 rtc/Maintenance Using BATT (Charge:100%) 45 secs
    2026-06-16 22:45:22 -0700 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to NUB rtc/SleepService Using BATT (Charge:100%) 2 secs
    2026-06-16 23:21:34 -0700 DarkWake            \tDarkWake from Deep Idle [CDNP] : due to smc.sysState.Wake wifibt E_PFN_NET_FOUND ARPT/ Using BATT 45 secs
    2026-06-16 23:23:43 -0700 Wake                \tWake from Deep Idle [CDNVA] : due to smc.sysState.Wake lid HID Activity Using BATT
    2026-06-16 22:29:43 -0700 Wake Requests       \t[process=dasd request=SleepService deltaSecs=939]
    """

    func testExtractsOnlyRealWakes() {
        // 4 wake/darkwake lines; the "Wake Requests" line is ignored.
        XCTAssertEqual(WakeMonitor.parse(log).count, 4)
    }

    func testCategorizesReasons() {
        let events = WakeMonitor.parse(log)
        XCTAssertEqual(events.filter { $0.reason == "Maintenance" }.count, 1)
        XCTAssertEqual(events.filter { $0.reason == "Background refresh" }.count, 1)
        XCTAssertEqual(events.filter { $0.reason == "Network" }.count, 1)
        XCTAssertEqual(events.filter { $0.reason == "User activity" }.count, 1)
    }

    func testTypesParsed() {
        let events = WakeMonitor.parse(log)
        XCTAssertEqual(events.filter { $0.type == "DarkWake" }.count, 3)
        XCTAssertEqual(events.filter { $0.type == "Wake" }.count, 1)
    }
}
