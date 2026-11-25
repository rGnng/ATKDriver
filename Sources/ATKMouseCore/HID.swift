import CoreGraphics
import Darwin
import Foundation
import IOKit
import IOKit.hid

public enum MouseError: LocalizedError {
    case unavailable(String), wrongReport, rejected, timeout, permission, occupied, access(IOReturn)

    public var errorDescription: String? {
        switch self {
        case let .unavailable(message): message
        case .wrongReport: "The mouse returned an invalid report."
        case .rejected: "The mouse rejected the request."
        case .timeout: "The mouse didn’t respond. Move it and try again."
        case .permission: "Allow ATK in System Settings → Privacy & Security → Input Monitoring, then reopen it."
        case .occupied: "Another app has exclusive access to this mouse. Release it there and refresh."
        case let .access(code): String(format: "Couldn’t access the mouse (0x%08x).", UInt32(bitPattern: code))
        }
    }
}

public enum Link: String, Codable, Sendable {
    case usb = "USB"
    case receiver = "USB receiver"
    case bluetooth = "Bluetooth"
}

public struct MouseDevice: Identifiable, Hashable, Codable, Sendable {
    public let id: UInt64
    public let vendor: Int
    public let product: Int
    public let name: String
    public let link: Link
    public let supportsConfiguration: Bool
    public let serialNumber: String?
    public let locationID: UInt32?
    public let usbRevision: Int?
    public let sharesKeyboardInterface: Bool?

    public var usbID: String { String(format: "%04x:%04x", vendor, product) }
    public var port: String? { locationID.map { String(format: "%08X", $0) } }
    public var revision: String? { usbRevision.map { String(format: "%X.%02X", $0 >> 8, $0 & 0xff) } }

    // Interfaces of one USB device share a location. Leave location-less devices distinct.
    var usbLocationKey: String? {
        guard link != .bluetooth, let port else { return nil }
        return "\(usbID)/\(port)"
    }

    public static func chooserLabels(for devices: [MouseDevice]) -> [UInt64: String] {
        let groups = Dictionary(grouping: devices) { "\($0.name) (\($0.link.rawValue))" }
        var labels: [UInt64: String] = [:]
        for (title, devices) in groups {
            for device in devices {
                guard devices.count > 1 else {
                    labels[device.id] = title
                    continue
                }
                let detail: String
                if let serial = device.serialNumber, devices.filter({ $0.serialNumber == serial }).count == 1 {
                    detail = "S/N \(serial)"
                } else if let port = device.port, devices.filter({ $0.port == port }).count == 1 {
                    detail = "Port \(port)"
                } else {
                    detail = "ID \(String(device.id, radix: 16, uppercase: true))"
                }
                labels[device.id] = "\(device.name) (\(device.link.rawValue), \(detail))"
            }
        }
        return labels
    }
}

struct ReportChannel: Equatable {
    let page: Int
    let inputBytes: Int
    let outputBytes: Int
    let featureBytes: Int

    static func find(in descriptor: Data) -> ReportChannel? {
        var global = [0: 0, 7: 0, 8: 0, 9: 0]
        var stack: [[Int: Int]] = []
        var usage: (Int, Int)?
        var collection: (page: Int, usage: Int)?
        var lengths: [Int: Int] = [:]
        var depth = 0
        var offset = 0
        let bytes = Array(descriptor)
        while offset < bytes.count {
            let prefix = Int(bytes[offset])
            offset += 1
            if prefix == 0xfe {
                guard offset + 2 <= bytes.count else { return nil }
                offset += Int(bytes[offset]) + 2
                guard offset <= bytes.count else { return nil }
                continue
            }
            let width = [0, 1, 2, 4][prefix & 3]
            guard offset + width <= bytes.count else { return nil }
            let value = (0..<width).reduce(0) { $0 | (Int(bytes[offset + $1]) << (8 * $1)) }
            offset += width
            let type = (prefix >> 2) & 3
            let tag = prefix >> 4
            switch (type, tag) {
            case (1, 10): stack.append(global)
            case (1, 11):
                guard let previous = stack.popLast() else { return nil }
                global = previous
            case (1, _) where global[tag] != nil: global[tag] = value
            case (2, 0) where usage == nil:
                usage = width == 4 ? (value >> 16, value & 0xffff) : (global[0, default: 0], value)
            case (0, 10):
                if depth == 0, value == 1 {
                    collection = usage
                    lengths.removeAll()
                }
                depth += 1
            case (0, 12):
                guard depth > 0 else { return nil }
                depth -= 1
                if depth == 0, let collection {
                    let input = lengths[8, default: 0]
                    let output = lengths[9, default: 0]
                    let feature = lengths[11, default: 0]
                    let isCompx = [0xff02, 0xff04].contains(collection.page)
                        && collection.usage == 2 && input == 128 && (output == 128 || feature == 128)
                    let isBitMouse = collection.page == 0xff05 && collection.usage == 1
                        && input == 504 && output == 504
                    if isCompx || isBitMouse {
                        return ReportChannel(page: collection.page, inputBytes: input / 8,
                                             outputBytes: output / 8, featureBytes: feature / 8)
                    }
                }
            case (0, 8), (0, 9), (0, 11):
                if depth > 0, global[8] == 8 {
                    let size = global[7, default: 0]
                    let count = global[9, default: 0]
                    guard size <= 65_536, count <= 65_536 else { return nil }
                    lengths[tag, default: 0] += size * count
                }
            default: break
            }
            if type == 0 { usage = nil }
        }
        return nil
    }
}

enum HID {
    static func hasInputAccess() -> Bool { CGPreflightListenEventAccess() }
    static func requestInputAccess() -> Bool { CGRequestListenEventAccess() }

    static let receiverRates: [String: Int] = [
        "3554:f505": 4000, "3554:f58a": 1000, "3554:f58d": 4000, "3554:f58e": 1000,
        "373b:1040": 8000, "373b:1085": 1000, "373b:111a": 8000, "373b:11d9": 8000,
        "373b:11dc": 8000, "373b:1216": 1000, "373b:10c9": 1000,
    ]

    struct Match {
        let info: MouseDevice
        let handle: IOHIDDevice
        let channel: ReportChannel?
    }

    static func matches() -> [Match] {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [kIOHIDVendorIDKey: 0x373b], [kIOHIDVendorIDKey: 0x3554],
        ] as CFArray)
        guard let handles = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return [] }
        let candidates: [Match] = handles.compactMap { handle in
            func number(_ key: String) -> Int { (IOHIDDeviceGetProperty(handle, key as CFString) as? NSNumber)?.intValue ?? 0 }
            func string(_ key: String) -> String? { IOHIDDeviceGetProperty(handle, key as CFString) as? String }
            var id: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(handle), &id) == KERN_SUCCESS else { return nil }
            let vendor = number(kIOHIDVendorIDKey)
            let product = number(kIOHIDProductIDKey)
            let usbID = String(format: "%04x:%04x", vendor, product)
            let transport = string(kIOHIDTransportKey) ?? ""
            let name = string(kIOHIDProductKey) ?? "ATK mouse"
            let isBluetooth = transport.localizedCaseInsensitiveContains("bluetooth")
            let isReceiver = receiverRates[usbID] != nil
                || name.localizedCaseInsensitiveContains("dongle")
                || name.localizedCaseInsensitiveContains("receiver")
            let link: Link = isBluetooth ? .bluetooth : (isReceiver ? .receiver : .usb)
            let descriptor = IOHIDDeviceGetProperty(handle, kIOHIDReportDescriptorKey as CFString) as? Data
            let channel = descriptor.flatMap(ReportChannel.find)
            let pointer = number(kIOHIDPrimaryUsagePageKey) == 1 && number(kIOHIDPrimaryUsageKey) == 2
            guard channel != nil || pointer else { return nil }
            let serial = string(kIOHIDSerialNumberKey)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let location = UInt32(exactly: number(kIOHIDLocationIDKey))
            let revision = number(kIOHIDVersionNumberKey)
            let info = MouseDevice(id: id, vendor: vendor, product: product, name: name, link: link,
                                   supportsConfiguration: channel != nil && channel?.page != 0xff05,
                                   serialNumber: serial?.isEmpty == false ? serial : nil,
                                   locationID: location == 0 ? nil : location,
                                   usbRevision: !isBluetooth && revision > 0 ? revision : nil,
                                   sharesKeyboardInterface: IOHIDDeviceConformsTo(handle, 1, 6))
            return Match(info: info, handle: handle, channel: channel)
        }
        return distinct(candidates)
    }

    static func distinct(_ candidates: [Match]) -> [Match] {
        let preferred = candidates.sorted {
            if $0.info.supportsConfiguration != $1.info.supportsConfiguration {
                return $0.info.supportsConfiguration
            }
            return $0.info.id < $1.info.id
        }
        var ports: Set<String> = []
        return preferred.filter {
            guard let key = $0.info.usbLocationKey else { return true }
            return ports.insert(key).inserted
        }.sorted { $0.info.id < $1.info.id }
    }
}

typealias Exchange = (_ frame: [UInt8], _ feature: Bool, _ match: ([UInt8]) -> Bool) throws -> [UInt8]?

final class HIDSession {
    private let device: IOHIDDevice
    private let buffer: UnsafeMutablePointer<UInt8>
    private let bufferSize = 256
    private let runLoop: CFRunLoop
    private let lock: Int32
    private var inbox: [[UInt8]] = []

    init(_ entry: HID.Match) throws {
        let path = NSTemporaryDirectory() + "/atkmouse-\(entry.info.id).lock"
        let lock = open(path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard lock >= 0 else { throw MouseError.unavailable("Couldn’t lock the mouse connection.") }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            close(lock)
            throw MouseError.unavailable("Another ATK operation is in progress.")
        }
        let status = IOHIDDeviceOpen(entry.handle, IOOptionBits(kIOHIDOptionsTypeNone))
        guard status == kIOReturnSuccess else {
            close(lock)
            if status == kIOReturnExclusiveAccess { throw MouseError.occupied }
            if status == kIOReturnNotPermitted || status == kIOReturnNotPrivileged { throw MouseError.permission }
            throw MouseError.access(status)
        }
        self.lock = lock
        device = entry.handle
        buffer = .allocate(capacity: bufferSize)
        runLoop = CFRunLoopGetCurrent()!
        IOHIDDeviceScheduleWithRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceRegisterInputReportCallback(device, buffer, bufferSize, { context, result, _, _, reportID, bytes, length in
            guard let context, result == kIOReturnSuccess, reportID == 8, length > 0 else { return }
            let owner = Unmanaged<HIDSession>.fromOpaque(context).takeUnretainedValue()
            if owner.inbox.count < 32 {
                owner.inbox.append(Array(UnsafeBufferPointer(start: bytes, count: length)))
            }
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    deinit {
        IOHIDDeviceUnscheduleFromRunLoop(device, runLoop, CFRunLoopMode.defaultMode.rawValue)
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        buffer.deallocate()
        close(lock)
    }

    func exchange(_ frame: [UInt8], _ feature: Bool, _ match: ([UInt8]) -> Bool) throws -> [UInt8]? {
        CFRunLoopRunInMode(.defaultMode, 0, false)
        inbox.removeAll(keepingCapacity: true)
        let type = feature ? kIOHIDReportTypeFeature : kIOHIDReportTypeOutput
        let status = IOHIDDeviceSetReport(device, type, 8, frame, frame.count)
        guard status == kIOReturnSuccess else { throw MouseError.access(status) }
        let deadline = ProcessInfo.processInfo.systemUptime + 0.8
        while true {
            for report in inbox {
                if match(report) { return report }
                if report.count == frame.count - 1 {
                    let numbered = [UInt8(8)] + report
                    if match(numbered) { return numbered }
                }
            }
            inbox.removeAll(keepingCapacity: true)
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { return nil }
            CFRunLoopRunInMode(.defaultMode, min(0.05, remaining), true)
        }
    }
}
