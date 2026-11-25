import XCTest
@testable import ATKMouseCore

final class DPIStagesTests: XCTestCase {
    func testAddInitializesBlankSlotBeforeIncreasingCount() throws {
        let fixture = Fixture(count: 2, active: 1)
        let original = fixture.bytes(at: 12, count: 8)
        try DPIStages.edit(.add, row: fixture.row, mouse: fixture.mouse)

        XCTAssertEqual(fixture.writeAddresses, [20, 0])
        XCTAssertEqual(fixture.bytes(at: 20, count: 4), Array(original.suffix(4)))
        XCTAssertEqual(fixture.bytes(at: 12, count: 8), original)
        XCTAssertEqual(fixture.row[2], 3)
        XCTAssertEqual(fixture.row[4], 1)
    }

    func testRemovingMiddleStageShiftsDPIAndColorAndRetainsActiveStage() throws {
        let fixture = Fixture(count: 4, active: 2)
        let sensitivity = fixture.bytes(at: 12, count: 16)
        let colors = fixture.bytes(at: 44, count: 16)
        try DPIStages.edit(.remove(2), row: fixture.row, mouse: fixture.mouse)

        XCTAssertEqual(fixture.bytes(at: 12, count: 12), Array(sensitivity[0..<4] + sensitivity[8..<16]))
        XCTAssertEqual(fixture.bytes(at: 44, count: 12), Array(colors[0..<4] + colors[8..<16]))
        XCTAssertEqual(fixture.row[2], 3)
        XCTAssertEqual(fixture.row[4], 1)
        XCTAssertEqual(fixture.row[0], 1)
    }

    func testRemovingActiveLastStageSelectsPreviousStageAndKeepsSavedSlot() throws {
        let fixture = Fixture(count: 3, active: 2)
        let saved = fixture.bytes(at: 20, count: 4)
        try DPIStages.edit(.remove(3), row: fixture.row, mouse: fixture.mouse)
        XCTAssertEqual(fixture.row[4], 1)
        try DPIStages.edit(.add, row: fixture.row, mouse: fixture.mouse)

        XCTAssertEqual(fixture.row[2], 3)
        XCTAssertEqual(fixture.row[4], 1)
        XCTAssertEqual(fixture.bytes(at: 20, count: 4), saved)
        XCTAssertEqual(fixture.writeAddresses, [0, 0])
    }

    func testFailedCountWriteRestoresShiftedRecords() throws {
        let fixture = Fixture(count: 3, active: 0)
        let original = fixture.memory
        fixture.ignoreWritesAt = 0

        XCTAssertThrowsError(try DPIStages.edit(.remove(1), row: fixture.row, mouse: fixture.mouse))
        XCTAssertEqual(fixture.memory, original)
        XCTAssertEqual(fixture.writeAddresses, [12, 44, 0, 44, 12])
    }

    func testStageLimitsAndInvalidSelectionNeverWrite() {
        let single = Fixture(count: 1, active: 0)
        XCTAssertThrowsError(try DPIStages.edit(.remove(1), row: single.row, mouse: single.mouse))
        XCTAssertEqual(single.writeAddresses, [])
        let full = Fixture(count: 8, active: 0)
        XCTAssertThrowsError(try DPIStages.edit(.add, row: full.row, mouse: full.mouse))
        XCTAssertThrowsError(try DPIStages.edit(.remove(9), row: full.row, mouse: full.mouse))
        XCTAssertEqual(full.writeAddresses, [])
    }
}

private final class Fixture {
    var memory = Array(repeating: UInt8(0), count: 76)
    var writeAddresses: [Int] = []
    var ignoreWritesAt: Int?

    init(count: Int, active: Int) {
        memory.replaceSubrange(0..<10, with: [1, UInt8(count), UInt8(active), 0, 0].flatMap { Compx.record([$0]) })
        for index in 0..<count {
            let dpi = UInt8(9 + index * 9)
            let offset = index * 4
            memory.replaceSubrange((12 + offset)..<(16 + offset), with: Compx.record([dpi, dpi, 0]))
            memory.replaceSubrange((44 + offset)..<(48 + offset), with: Compx.record([UInt8(index), 0, 0]))
        }
    }

    var row: [UInt8] { bytes(at: 0, count: 10) }

    func bytes(at address: Int, count: Int) -> [UInt8] {
        Array(memory[address..<address + count])
    }

    var mouse: Compx {
        let channel = ReportChannel(page: 0xff02, inputBytes: 16, outputBytes: 16, featureBytes: 0)
        return Compx(channel: channel) { [self] request, _, _ in
            let command = request[1]
            let address = Int(request[3]) << 8 | Int(request[4])
            let length = Int(request[5])
            if command == 7 {
                writeAddresses.append(address)
                if address != ignoreWritesAt {
                    memory.replaceSubrange(address..<address + length, with: request[6..<6 + length])
                }
            }
            return Compx.frame(command, address: address, length: length, data: bytes(at: address, count: length))
        }
    }
}
