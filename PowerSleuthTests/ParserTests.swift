import XCTest
@testable import PowerSleuth

/// Regression tests for the `top` parser. These lock in two bugs found in review:
/// (1) multi-word COMMAND names ("Google Chrome He") were dropped, and
/// (2) the MEM column's trailing +/- compression flag made memory always parse as 0.
final class TopParserTests: XCTestCase {

    // Mirrors real `top -l 2` output: two blocks, second is authoritative.
    private let sample = """
    Processes: 600 total, 3 running
    PID    COMMAND          %CPU MEM    POWER STATE
    1      stale            0.0  10M    0.0   sleeping

    PID    COMMAND          %CPU MEM    POWER STATE
    78695  WindowServer     51.3 1296M- 52.0  sleeping
    39922  Google Chrome He 20.5 589M-  20.5  sleeping
    16949  Claude Helper (R 8.4  632M+  8.4   sleeping
    """

    func testParsesSecondBlockOnly() {
        let rows = ProcessSampler.parseTopOutput(sample)
        // Only the 3 rows under the LAST "PID" header, not the stale first block.
        XCTAssertEqual(rows.count, 3)
    }

    func testCapturesMultiWordProcessNames() {
        let rows = ProcessSampler.parseTopOutput(sample)
        XCTAssertTrue(rows.contains { $0.name == "Google Chrome He" })
        XCTAssertTrue(rows.contains { $0.name == "Claude Helper (R" })
    }

    func testMemoryIsNeverZero() {
        let rows = ProcessSampler.parseTopOutput(sample)
        XCTAssertFalse(rows.isEmpty)
        XCTAssertTrue(rows.allSatisfy { $0.memMb > 0 },
                      "MEM suffix (+/-) must be stripped before parsing")
    }

    func testSortedByEnergyImpactDescending() {
        let rows = ProcessSampler.parseTopOutput(sample)
        XCTAssertEqual(rows.first?.name, "WindowServer")
        XCTAssertEqual(rows.first?.energyImpact, 52.0)
        XCTAssertEqual(rows.first?.cpuPct, 51.3)
    }

    func testMemUnitParsing() {
        XCTAssertEqual(ProcessSampler.parseMem("589M-"), 589, accuracy: 0.01)
        XCTAssertEqual(ProcessSampler.parseMem("1296M+"), 1296, accuracy: 0.01)
        XCTAssertEqual(ProcessSampler.parseMem("1.5G"), 1536, accuracy: 0.01)
        XCTAssertEqual(ProcessSampler.parseMem("2048K"), 2, accuracy: 0.01)
    }

    func testEmptyOutputReturnsEmpty() {
        XCTAssertTrue(ProcessSampler.parseTopOutput("").isEmpty)
    }
}

/// Regression tests for the `nettop` parser. Locks in the bug where nettop's
/// space-padded output was split on tabs, yielding zero rows every time. The fix
/// uses `nettop -J` CSV output.
final class NettopParserTests: XCTestCase {

    private let csv = """
    ,bytes_in,bytes_out,re-tx
    CloudflareWARP.123,853533690,213677012,9222
    Google Chrome H.456,139320494,228436,766
    idle.789,0,0,0
    """

    func testParsesCSVRows() {
        let rows = NetworkSampler.parseNettop(csv)
        // 3 process rows; the header row (empty name) is skipped.
        XCTAssertEqual(rows.count, 3)
    }

    func testSkipsHeaderRow() {
        let rows = NetworkSampler.parseNettop(csv)
        XCTAssertFalse(rows.contains { $0.name.isEmpty })
    }

    func testStripsPidAndKeepsByteCounts() {
        let rows = NetworkSampler.parseNettop(csv)
        let chrome = rows.first { $0.name == "Google Chrome H" }
        XCTAssertNotNil(chrome)
        XCTAssertEqual(chrome?.bytesIn, 139320494)
        XCTAssertEqual(chrome?.bytesOut, 228436)
        XCTAssertEqual(chrome?.retransmits, 766)
    }

    func testSortedByTotalBytesDescending() {
        let rows = NetworkSampler.parseNettop(csv)
        XCTAssertEqual(rows.first?.name, "CloudflareWARP")
    }

    func testEmptyOutputReturnsEmpty() {
        XCTAssertTrue(NetworkSampler.parseNettop("").isEmpty)
    }
}
