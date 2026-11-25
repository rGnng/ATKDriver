import XCTest
@testable import ATKMouseCore

final class CompxTests: XCTestCase {
    private let channel = ReportChannel(page: 0xff02, inputBytes: 16, outputBytes: 16, featureBytes: 0)

    func testIdentityRequest() {
        XCTAssertEqual(Compx.frame(16, address: 0, length: 0, data: []),
                       [8, 16, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 61])
    }

    func testV3DescriptorSelectsTheConfigurationChannel() {
        let descriptor: [UInt8] = [
            0x05, 0x0c, 0x09, 0x01, 0xa1, 1, 0x85, 5, 0x75, 16, 0x95, 1, 0x81, 0, 0xc0,
            0x06, 0x02, 0xff, 0x09, 2, 0xa1, 1, 0x85, 19, 0x75, 8, 0x95, 19, 0x81, 0, 0x91, 0, 0xc0,
            0x06, 0x02, 0xff, 0x09, 2, 0xa1, 1, 0x85, 8, 0x75, 8, 0x95, 16, 0x81, 0, 0x91, 0, 0xc0,
        ]
        XCTAssertEqual(ReportChannel.find(in: Data(descriptor)), channel)
        XCTAssertNil(ReportChannel.find(in: Data(descriptor.dropLast())))
    }

    func testReadRejectsWrongAddressAndInvalidChecksum() throws {
        let mouse = Compx(channel: channel) { request, feature, match in
            XCTAssertFalse(feature)
            XCTAssertEqual(Array(request.prefix(6)), [8, 8, 0, 0, 12, 2])
            let wrongAddress = Compx.frame(8, address: 10, length: 2, data: [23, 23])
            XCTAssertFalse(match(wrongAddress))
            var badChecksum = Compx.frame(8, address: 12, length: 2, data: [23, 23])
            XCTAssertTrue(match(badChecksum))
            badChecksum[16] ^= 1
            return badChecksum
        }
        XCTAssertThrowsError(try mouse.read(12, 2))
    }

    func testWriteRequiresReadbackEvenWithoutAcknowledgment() throws {
        var commands: [UInt8] = []
        var value: [UInt8] = [1, 84]
        let mouse = Compx(channel: channel) { request, _, _ in
            commands.append(request[1])
            switch request[1] {
            case 7: return nil
            case 8: return Compx.frame(8, address: 0, length: 2, data: value)
            default: XCTFail("Unexpected command"); return nil
            }
        }
        XCTAssertThrowsError(try mouse.write(0, [2, 83], replacing: [1, 84]))
        XCTAssertEqual(commands, [8, 7, 8])
        commands.removeAll()
        value = [2, 83]
        XCTAssertThrowsError(try mouse.write(0, [4, 81], replacing: [1, 84]))
        XCTAssertEqual(commands, [8])
    }

    func testV3SensitivityEncodingMatchesDeviceRecords() throws {
        XCTAssertEqual(PixArt3395SE.read(23, high: false), 1000)
        XCTAssertEqual(PixArt3395SE.read(37, high: false), 1600)
        XCTAssertEqual(PixArt3395SE.read(118, high: true), 10100)
        XCTAssertEqual(PixArt3395SE.read(6, high: false), 300)
        XCTAssertNil(PixArt3395SE.read(7, high: false))
        for dpi in [200, 300, 800, 1000, 1600, 5000, 5050, 10000, 10100, 18000] {
            let (code, high) = try PixArt3395SE.encode(dpi)
            XCTAssertEqual(PixArt3395SE.read(code, high: high), dpi)
        }
        XCTAssertThrowsError(try PixArt3395SE.encode(10150))
    }
}
