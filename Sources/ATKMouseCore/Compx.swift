import Foundation

struct Compx {
    let channel: ReportChannel
    let exchange: Exchange

    static func record(_ data: [UInt8]) -> [UInt8] {
        data + [UInt8(truncatingIfNeeded: 0x55 - data.reduce(0) { $0 + Int($1) })]
    }

    static func valid(_ data: [UInt8]) -> Bool {
        data.reduce(0, &+) == 0x55
    }

    static func frame(_ command: UInt8, address: Int, length: Int, data: [UInt8]) -> [UInt8] {
        record([8, command, 0, UInt8(address >> 8), UInt8(truncatingIfNeeded: address), UInt8(length)]
               + data + Array(repeating: 0, count: 10 - data.count))
    }

    func request(_ command: UInt8, address: Int = 0, length: Int? = nil, data: [UInt8] = []) throws -> [UInt8] {
        let length = length ?? data.count
        guard 0 <= address, address <= 0xffff, data.count <= length, (0...10).contains(length) else {
            throw MouseError.wrongReport
        }
        let frame = Self.frame(command, address: address, length: length, data: data)
        let writes = command == 7 || command == 15
        let feature = channel.outputBytes != 16 || (writes && channel.featureBytes == 16)
        let reply = try exchange(frame, feature) {
            $0.count == 17 && $0[0] == 8 && $0[1] == command
                && ((command != 7 && command != 8) || $0[3...5] == frame[3...5])
        }
        guard let reply else {
            if writes { return [] }
            throw MouseError.timeout
        }
        guard Self.valid(reply), reply[5] <= 10 else { throw MouseError.wrongReport }
        guard reply[2] != 0xff else { throw MouseError.rejected }
        return Array(reply[6..<16])
    }

    static func deviceUID(from identity: [UInt8]) -> String? {
        guard identity.count >= 10 else { return nil }
        let bytes = identity[6..<10]
        guard !bytes.allSatisfy({ $0 == 0 }), !bytes.allSatisfy({ $0 == 0xff }) else { return nil }
        return bytes.map { String(format: "%02X", $0) }.joined()
    }

    static func batteryMillivolts(from report: [UInt8]) -> Int? {
        guard report.count >= 4 else { return nil }
        let voltage = Int(report[2]) << 8 | Int(report[3])
        return voltage > 0 && voltage < 0xffff ? voltage : nil
    }

    func read(_ address: Int, _ length: Int) throws -> [UInt8] {
        Array(try request(8, address: address, length: length).prefix(length))
    }

    func write(_ address: Int, _ data: [UInt8], replacing original: [UInt8]) throws {
        guard data != original else { return }
        guard try read(address, data.count) == original else {
            throw MouseError.unavailable("The mouse settings changed. Refresh and try again.")
        }
        _ = try request(7, address: address, data: data)
        guard try read(address, data.count) == data else {
            throw MouseError.unavailable("The mouse didn’t confirm the setting.")
        }
    }
}
