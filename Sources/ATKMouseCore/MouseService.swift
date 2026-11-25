import Foundation

public struct DPIStage: Identifiable, Codable, Sendable {
    public let id: Int
    public let x: Int?
    public let y: Int?
}

public enum MouseSetting: String, CaseIterable, Codable, Sendable {
    case liftOff = "lift-off"
    case debounce, sleep
    case motionSync = "motion-sync"
    case angleSnap = "angle-snap"
    case rippleControl = "ripple-control"
    case performance

    public var label: String {
        switch self {
        case .liftOff: "Lift-off distance"
        case .debounce: "Debounce"
        case .sleep: "Sleep after"
        case .motionSync: "Motion Sync"
        case .angleSnap: "Angle snapping"
        case .rippleControl: "Ripple control"
        case .performance: "Sensor mode"
        }
    }

    public var choices: [Int] {
        switch self {
        case .liftOff: [1, 2]
        case .debounce: [0, 1, 2, 4, 8, 15, 20]
        case .sleep: [30, 60, 120, 180, 300, 600, 900, 1200, 1800]
        case .motionSync, .angleSnap, .rippleControl, .performance: [0, 1]
        }
    }

    public func description(of value: Int) -> String {
        switch self {
        case .liftOff: "\(value) mm"
        case .debounce: "\(value) ms"
        case .sleep: value < 60 ? "\(value) sec" : (value % 60 == 0 ? "\(value / 60) min" : "\(value) sec")
        case .performance: value == 0 ? "Standard" : "Competitive"
        default: value == 0 ? "Off" : "On"
        }
    }
}

public enum MouseButton: String, CaseIterable, Codable, Sendable {
    case left, right, middle, back, forward, dpi

    public var label: String {
        self == .dpi ? "DPI button" : rawValue.capitalized
    }
}

public enum ButtonAction: String, CaseIterable, Codable, Sendable {
    case left, right, middle, back, forward, disabled
    case dpiCycle = "dpi-cycle"
    case dpiUp = "dpi-up"
    case dpiDown = "dpi-down"

    public var label: String {
        switch self {
        case .dpiCycle: "Cycle DPI"
        case .dpiUp: "Increase DPI"
        case .dpiDown: "Decrease DPI"
        default: rawValue.capitalized
        }
    }

    var bytes: [UInt8] {
        switch self {
        case .left: [1, 1, 0]
        case .right: [1, 2, 0]
        case .middle: [1, 4, 0]
        case .back: [1, 8, 0]
        case .forward: [1, 16, 0]
        case .disabled: [1, 0, 0]
        case .dpiCycle: [2, 1, 0]
        case .dpiUp: [2, 2, 0]
        case .dpiDown: [2, 3, 0]
        }
    }
}

public struct MouseSnapshot: Codable, Sendable {
    public let device: MouseDevice
    public let company: Int
    public let model: Int
    public let deviceUID: String?
    public let firmware: String?
    public let battery: Int?
    public let charging: Bool?
    public let batteryMillivolts: Int?
    public let profile: Int?
    public let pollingRate: Int
    public let pollingRates: [Int]
    public let activeStage: Int
    public let stages: [DPIStage]
    public let settings: [MouseSetting: Int]
    public let buttons: [MouseButton: ButtonAction]
    public let writable: Bool
}

public enum MouseChange: Sendable {
    case rate(Int), stage(Int), dpi(stage: Int, x: Int, y: Int), profile(Int)
    case addStage, removeStage(Int)
    case setting(MouseSetting, Int), button(MouseButton, ButtonAction)
}

enum PixArt3395SE {
    // This sensor uses a quantized index with a dedicated code for 300 DPI.
    private static let codes: [UInt8] = (1...200).map { (step: Int) -> UInt8 in
        if step == 6 { return 6 }
        let index: Int = (step * 20 - 1) / 17
        return UInt8(index)
    }

    static func read(_ code: UInt8, high: Bool) -> Int? {
        guard let position = codes.firstIndex(of: code) else { return nil }
        let dpi = (position + 1) * 50
        return high && (5050...9000).contains(dpi) ? dpi * 2 : dpi
    }

    static func encode(_ dpi: Int) throws -> (UInt8, Bool) {
        let high = dpi > 10_000
        let step = high ? 100 : 50
        guard (200...18_000).contains(dpi), dpi.isMultiple(of: step) else {
            throw MouseError.unavailable("Enter 200–10,000 DPI in steps of 50, or 10,100–18,000 in steps of 100.")
        }
        return (codes[dpi / step - 1], high)
    }
}

public enum MouseService {
    public static let maximumDPIStages = DPIStages.capacity
    static let rates: [Int: UInt8] = [125: 8, 250: 4, 500: 2, 1000: 1, 2000: 16, 4000: 32, 8000: 64]

    public static func devices() -> [MouseDevice] {
        HID.matches().map(\.info)
    }

    public static func hasInputAccess() -> Bool {
        HID.hasInputAccess()
    }

    @discardableResult
    public static func requestInputAccess() -> Bool {
        HID.requestInputAccess()
    }

    public static func read(_ device: MouseDevice) throws -> MouseSnapshot {
        try withCompx(device) { mouse in
            let identity = try mouse.request(16)
            let uid = Compx.deviceUID(from: identity)
            let firmware = try? mouse.request(18)
            let version = firmware.map { String(format: "%x.%02x", $0[0], $0[1]) }
            let power = try? mouse.request(4)
            let percent = power.flatMap { $0[0] <= 100 ? Int($0[0]) : nil }
            let voltage = power.flatMap { Compx.batteryMillivolts(from: $0) }
            let profile = try? profileNumber(mouse)
            let row = try systemRow(mouse)
            let rate = rates.first(where: { $0.value == row[0] })?.key
            guard let rate else { throw MouseError.wrongReport }
            let writable = supportsV3(device, identity)
            let maxRate = writable ? 1000 : rate
            var stages: [DPIStage] = []
            for index in stride(from: 0, to: Int(row[2]), by: 2) {
                let pair = try mouse.read(12 + 4 * index, 8)
                for offset in 0..<min(2, Int(row[2]) - index) {
                    let entry = Array(pair[(4 * offset)..<(4 * offset + 4)])
                    let decoded = writable && Compx.valid(entry)
                    stages.append(DPIStage(id: index + offset + 1,
                                           x: decoded ? PixArt3395SE.read(entry[0], high: entry[2] & 2 != 0) : nil,
                                           y: decoded ? PixArt3395SE.read(entry[1], high: entry[2] & 32 != 0) : nil))
                }
            }
            let settings = writable ? readSettings(mouse) : [:]
            let buttons = writable ? readButtons(mouse) : [:]
            return MouseSnapshot(device: device, company: Int(identity[0]), model: Int(identity[1]),
                                 deviceUID: uid, firmware: version, battery: percent,
                                 charging: power.flatMap { $0[1] <= 1 ? $0[1] == 1 : nil },
                                 batteryMillivolts: voltage, profile: profile, pollingRate: rate,
                                 pollingRates: rates.keys.filter { $0 <= maxRate }.sorted(),
                                 activeStage: Int(row[4]) + 1, stages: stages, settings: settings,
                                 buttons: buttons, writable: writable)
        }
    }

    public static func apply(_ change: MouseChange, to device: MouseDevice, expectedProfile: Int? = nil) throws {
        try withCompx(device) { mouse in
            guard supportsV3(device, try mouse.request(16)) else {
                throw MouseError.unavailable("Settings are read-only for this mouse or connection.")
            }
            if let expectedProfile, try profileNumber(mouse) != expectedProfile {
                throw MouseError.unavailable("The mouse changed profiles. Refresh and try again.")
            }
            switch change {
            case let .rate(hz):
                guard hz <= 1000, let value = rates[hz] else {
                    throw MouseError.unavailable("Choose 125, 250, 500, or 1000 Hz.")
                }
                let row = try systemRow(mouse)
                try writeField(mouse, original: row, address: 0, offset: 0, value: value)
            case let .stage(stage):
                let row = try systemRow(mouse)
                guard (1...Int(row[2])).contains(stage) else { throw MouseError.wrongReport }
                try writeField(mouse, original: row, address: 0, offset: 4, value: UInt8(stage - 1))
            case .addStage:
                try DPIStages.edit(.add, row: systemRow(mouse), mouse: mouse)
            case let .removeStage(stage):
                try DPIStages.edit(.remove(stage), row: systemRow(mouse), mouse: mouse)
            case let .dpi(stage, x, y):
                let row = try systemRow(mouse)
                guard (1...Int(row[2])).contains(stage) else { throw MouseError.wrongReport }
                let (xCode, xHigh) = try PixArt3395SE.encode(x)
                let (yCode, yHigh) = try PixArt3395SE.encode(y)
                try updatePair(mouse, base: 12, index: stage - 1) { previous in
                    let flags = (previous[2] & ~UInt8(0x22)) | (xHigh ? 2 : 0) | (yHigh ? 32 : 0)
                    return [xCode, yCode, flags]
                }
            case let .profile(number):
                guard (1...4).contains(number) else { throw MouseError.wrongReport }
                if try profileNumber(mouse) != number {
                    _ = try mouse.request(15, data: [UInt8(number - 1)])
                    guard try profileNumber(mouse) == number else { throw MouseError.rejected }
                }
            case let .setting(setting, value):
                try writeSetting(mouse, setting, value)
            case let .button(button, action):
                guard button != .left, let index = MouseButton.allCases.firstIndex(of: button) else {
                    throw MouseError.unavailable("The left button keeps its primary-click assignment.")
                }
                try updatePair(mouse, base: 96, index: index) { _ in action.bytes }
            }
        }
    }

    private static func supportsV3(_ device: MouseDevice, _ identity: [UInt8]) -> Bool {
        identity.prefix(2).elementsEqual([2, 73]) && device.link != .bluetooth
    }

    private static func profileNumber(_ mouse: Compx) throws -> Int {
        let index = Int(try mouse.request(14)[0])
        guard index < 4 else { throw MouseError.wrongReport }
        return index + 1
    }

    private static func systemRow(_ mouse: Compx) throws -> [UInt8] {
        let row = try mouse.read(0, 10)
        guard (1...DPIStages.capacity).contains(Int(row[2])), row[4] < row[2], [0, 2, 4].allSatisfy({
            Compx.valid(Array(row[$0..<$0 + 2]))
        }) else { throw MouseError.wrongReport }
        return row
    }

    private static func readSettings(_ mouse: Compx) -> [MouseSetting: Int] {
        var values: [MouseSetting: Int] = [:]
        if let lod = try? mouse.read(10, 2), Compx.valid(lod) { values[.liftOff] = Int(lod[0]) }
        if let flags = try? mouse.read(169, 10) {
            for (setting, offset) in [(MouseSetting.debounce, 0), (.motionSync, 2), (.angleSnap, 6), (.rippleControl, 8)] {
                if Compx.valid(Array(flags[offset..<offset + 2])) { values[setting] = Int(flags[offset]) }
            }
        }
        if let sensor = try? mouse.read(181, 6) {
            if Compx.valid(Array(sensor[2..<4])) { values[.sleep] = Int(sensor[2]) * 10 }
            if Compx.valid(Array(sensor[4..<6])) { values[.performance] = Int(sensor[4]) }
        }
        return values
    }

    private static func readButtons(_ mouse: Compx) -> [MouseButton: ButtonAction] {
        var result: [MouseButton: ButtonAction] = [:]
        for index in stride(from: 0, to: MouseButton.allCases.count, by: 2) {
            guard let pair = try? mouse.read(96 + 4 * index, 8) else { continue }
            for offset in 0..<2 {
                let record = Array(pair[(4 * offset)..<(4 * offset + 4)])
                if Compx.valid(record) {
                    result[MouseButton.allCases[index + offset]] = ButtonAction.allCases.first {
                        record.prefix(3).elementsEqual($0.bytes)
                    }
                }
            }
        }
        return result
    }

    private static func writeSetting(_ mouse: Compx, _ setting: MouseSetting, _ value: Int) throws {
        guard setting.choices.contains(value) else { throw MouseError.wrongReport }
        switch setting {
        case .liftOff:
            let original = try mouse.read(10, 2)
            try writeField(mouse, original: original, address: 10, offset: 0, value: UInt8(value))
        case .performance:
            let original = try mouse.read(181, 6)
            try writeField(mouse, original: original, address: 181, offset: 4, value: UInt8(value))
        case .sleep:
            let original = try mouse.read(181, 6)
            let advanced = try mouse.read(169, 10)
            let setting = UInt8(value / 10)
            let newAdvanced = try replacing(advanced, offset: 4, value: setting)
            try mouse.write(169, newAdvanced, replacing: advanced)
            do {
                try writeField(mouse, original: original, address: 181, offset: 2, value: setting)
            } catch {
                try mouse.write(169, advanced, replacing: newAdvanced)
                throw error
            }
        case .debounce, .motionSync, .angleSnap, .rippleControl:
            let offsets: [MouseSetting: Int] = [.debounce: 0, .motionSync: 2, .angleSnap: 6, .rippleControl: 8]
            let original = try mouse.read(169, 10)
            try writeField(mouse, original: original, address: 169, offset: offsets[setting]!, value: UInt8(value))
        }
    }

    private static func replacing(_ row: [UInt8], offset: Int, value: UInt8) throws -> [UInt8] {
        guard Compx.valid(Array(row[offset..<offset + 2])) else { throw MouseError.wrongReport }
        var updated = row
        updated.replaceSubrange(offset..<offset + 2, with: Compx.record([value]))
        return updated
    }

    private static func writeField(_ mouse: Compx, original: [UInt8], address: Int, offset: Int, value: UInt8) throws {
        try mouse.write(address, replacing(original, offset: offset, value: value), replacing: original)
    }

    private static func updatePair(_ mouse: Compx, base: Int, index: Int, update: ([UInt8]) -> [UInt8]) throws {
        let address = base + (index / 2) * 8
        let offset = (index % 2) * 4
        let pair = try mouse.read(address, 8)
        let current = Array(pair[offset..<offset + 4])
        guard Compx.valid(current) else { throw MouseError.wrongReport }
        var updated = pair
        updated.replaceSubrange(offset..<offset + 4, with: Compx.record(update(current)))
        try mouse.write(address, updated, replacing: pair)
    }

    private static func withCompx<T>(_ device: MouseDevice, _ visit: (Compx) throws -> T) throws -> T {
        guard let entry = HID.matches().first(where: { $0.info == device }) else {
            throw MouseError.unavailable("The mouse disconnected.")
        }
        guard let channel = entry.channel, channel.page != 0xff05 else {
            throw MouseError.unavailable("This connection has no supported configuration channel.")
        }
        let session = try HIDSession(entry)
        return try visit(Compx(channel: channel, exchange: session.exchange))
    }
}
