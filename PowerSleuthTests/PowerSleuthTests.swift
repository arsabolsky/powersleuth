import XCTest
@testable import PowerSleuth

final class AssertionParserTests: XCTestCase {

    func testParsesPreventSleep() {
        let output = """
        Assertion status system-wide:
           BackgroundTask                 0
           ApplePushServiceTask           0
           PreventUserIdleDisplaySleep    1
           PreventUserIdleSystemSleep     1
           PreventSystemSleep             0
           ExternalMedia                  0
           MaintenanceWake                0
           UserIsActive                   1

        Listed by owning process:
           pid 559(bluetoothd): [0x00016d8500000035] 00:01:14 PreventUserIdleSystemSleep named: "com.apple.BTStack.HIDPOW"
        	Timeout will fire in 6886 secs Action=TimeoutActionRelease
           pid 559(bluetoothd): [0x0001bc2600001148] 15:44:37 PreventUserIdleSystemSleep named: "com.apple.BTStack.HID"
        """
        let assertions = AssertionMonitor.parse(pmsetOutput: output)
        XCTAssertEqual(assertions.count, 2)
        XCTAssertEqual(assertions[0].processName, "bluetoothd")
        XCTAssertEqual(assertions[0].assertionType, "PreventUserIdleSystemSleep")
    }

    func testParsesMultipleProcesses() {
        let output = """
           pid 1234(loginwindow): [0x001] 00:05:00 PreventUserIdleDisplaySleep named: "UserIsActive"
           pid 5678(coreaudiod): [0x002] 00:10:00 PreventUserIdleSystemSleep named: "com.apple.audio.jack"
        """
        let assertions = AssertionMonitor.parse(pmsetOutput: output)
        XCTAssertEqual(assertions.count, 2)
        XCTAssertEqual(assertions[1].processName, "coreaudiod")
    }

    func testEmptyOutputReturnsEmpty() {
        let assertions = AssertionMonitor.parse(pmsetOutput: "")
        XCTAssertTrue(assertions.isEmpty)
    }
}

final class DrainLevelTests: XCTestCase {
    func testLevels() {
        XCTAssertEqual(DrainLevel.from(watts: 2), .efficient)
        XCTAssertEqual(DrainLevel.from(watts: 8), .moderate)
        XCTAssertEqual(DrainLevel.from(watts: 15), .elevated)
        XCTAssertEqual(DrainLevel.from(watts: 25), .heavy)
    }
}

final class BatterySnapshotTests: XCTestCase {
    func testWattsCalculation() {
        let s = BatterySnapshot(
            id: nil, timestamp: Date(),
            percentage: 80, voltageMv: 12000, amperageMa: -2000,
            temperatureC: 35.0, isCharging: false,
            powerSource: "Battery Power", thermalState: 0, lowPowerMode: false,
            systemWatts: 0
        )
        XCTAssertEqual(s.watts, 24.0, accuracy: 0.001)
    }

    func testWattsZeroWhenCharging() {
        let s = BatterySnapshot(
            id: nil, timestamp: Date(),
            percentage: 80, voltageMv: 12000, amperageMa: 1000,
            temperatureC: 35.0, isCharging: true,
            powerSource: "AC Power", thermalState: 0, lowPowerMode: false,
            systemWatts: 0
        )
        XCTAssertEqual(s.watts, 0.0)
    }
}
