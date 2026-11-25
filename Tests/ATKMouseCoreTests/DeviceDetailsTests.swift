import XCTest
@testable import ATKMouseCore

final class DeviceDetailsTests: XCTestCase {
    func testSingleMouseHasAChooserLabel() {
        let mouse = device(1, serial: "VX01")
        XCTAssertEqual(MouseDevice.chooserLabels(for: [mouse]), [1: "VXE V3 Pro NK (USB)"])
    }

    func testIdenticalModelsSeparateBySerialPortOrRegistryID() {
        let devices = [
            device(1, serial: "VX01"),
            device(2, serial: "VX02"),
            device(3, serial: "duplicate", location: 0x0210_0000),
            device(4, serial: "duplicate", location: 0x0220_0000),
            device(5),
        ]
        let labels = MouseDevice.chooserLabels(for: devices)
        XCTAssertEqual(labels[1], "VXE V3 Pro NK (USB, S/N VX01)")
        XCTAssertEqual(labels[2], "VXE V3 Pro NK (USB, S/N VX02)")
        XCTAssertEqual(labels[3], "VXE V3 Pro NK (USB, Port 02100000)")
        XCTAssertEqual(labels[4], "VXE V3 Pro NK (USB, Port 02200000)")
        XCTAssertEqual(labels[5], "VXE V3 Pro NK (USB, ID 5)")
    }

    func testUSBInterfacesShareLocationIdentityWithoutMergingSeparateMice() {
        let first = device(1, serial: "VX01", location: 0x0210_0000)
        let otherInterface = device(2, serial: "VX01", location: 0x0210_0000)
        let secondMouse = device(3, serial: "VX01", location: 0x0220_0000)
        XCTAssertEqual(first.usbLocationKey, otherInterface.usbLocationKey)
        XCTAssertNotEqual(first.usbLocationKey, secondMouse.usbLocationKey)
        XCTAssertNil(device(4, location: 0x0210_0000, link: .bluetooth).usbLocationKey)
        XCTAssertEqual(first.revision, "1.30")
    }

    func testReadoutDecodesTheDeviceUIDAndVoltage() {
        XCTAssertEqual(Compx.deviceUID(from: [2, 73, 0, 0, 0, 0, 0x09, 0x05, 0xA1, 0xCA]), "0905A1CA")
        XCTAssertNil(Compx.deviceUID(from: [2, 73, 0, 0, 0, 0, 0, 0, 0, 0]))
        XCTAssertNil(Compx.deviceUID(from: [2, 73, 0, 0, 0, 0, 255, 255, 255, 255]))
        XCTAssertNil(Compx.deviceUID(from: [2, 73]))
        XCTAssertEqual(Compx.batteryMillivolts(from: [100, 1, 0x10, 0x68]), 4200)
        XCTAssertNil(Compx.batteryMillivolts(from: [100, 1, 0, 0]))
        XCTAssertNil(Compx.batteryMillivolts(from: [100, 1, 255, 255]))
    }

    private func device(_ id: UInt64, serial: String? = nil, location: UInt32? = nil,
                        link: Link = .usb) -> MouseDevice {
        MouseDevice(id: id, vendor: 0x373b, product: 0x10e8, name: "VXE V3 Pro NK", link: link,
                    supportsConfiguration: true, serialNumber: serial, locationID: location, usbRevision: 0x0130,
                    sharesKeyboardInterface: nil)
    }
}
