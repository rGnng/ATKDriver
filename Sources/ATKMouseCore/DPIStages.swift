import Foundation

enum DPIStageEdit {
    case add
    case remove(Int)
}

enum DPIStages {
    static let capacity = 8

    private struct Block {
        let address: Int
        let previous: [UInt8]
        let next: [UInt8]
    }

    static func edit(_ edit: DPIStageEdit, row: [UInt8], mouse: Compx) throws {
        let count = Int(row[2])
        let active = Int(row[4])
        var updatedRow = row
        var blocks: [Block] = []

        switch edit {
        case .add:
            guard count < capacity else {
                throw MouseError.unavailable("This mouse can store up to \(capacity) DPI stages.")
            }

            // Restore a valid saved slot. If it’s blank, initialize it before making it selectable.
            let blockAddress = pairAddress(base: 12, index: count)
            let pair = try mouse.read(blockAddress, 8)
            let offset = 4 * (count % 2)
            let saved = Array(pair[offset..<offset + 4])
            if !validSensitivity(saved) {
                let source = try readRecords(base: 12, count: count, mouse: mouse)[active]
                guard validSensitivity(source) else { throw MouseError.wrongReport }
                var updated = pair
                updated.replaceSubrange(offset..<offset + 4, with: source)
                blocks.append(Block(address: blockAddress, previous: pair, next: updated))
            }
            updatedRow.replaceSubrange(2..<4, with: Compx.record([UInt8(count + 1)]))

        case let .remove(stage):
            guard count > 1 else {
                throw MouseError.unavailable("Keep at least one DPI stage.")
            }
            guard (1...count).contains(stage) else {
                throw MouseError.unavailable("This stage is no longer available. Refresh and try again.")
            }
            let removed = stage - 1
            if removed < count - 1 {
                // The firmware stores a contiguous list. Shift both the sensitivity and its color.
                for base in [12, 44] {
                    let records = try readRecords(base: base, count: count, mouse: mouse)
                    if base == 12, !records[(removed + 1)..<count].allSatisfy(validSensitivity) {
                        throw MouseError.wrongReport
                    }
                    var shifted = records
                    shifted.replaceSubrange(removed..<count - 1, with: records[(removed + 1)..<count])
                    for index in stride(from: (removed / 2) * 2, to: count - 1, by: 2) {
                        blocks.append(Block(address: pairAddress(base: base, index: index),
                                            previous: records[index] + records[index + 1],
                                            next: shifted[index] + shifted[index + 1]))
                    }
                }
            }
            let nextActive = active > removed ? active - 1 : min(active, count - 2)
            updatedRow.replaceSubrange(2..<6, with: Compx.record([UInt8(count - 1)]) +
                                       Compx.record([UInt8(nextActive)]))
        }
        blocks.append(Block(address: 0, previous: row, next: updatedRow))
        try write(blocks, mouse: mouse)
    }

    private static func validSensitivity(_ record: [UInt8]) -> Bool {
        Compx.valid(record) && PixArt3395SE.read(record[0], high: record[2] & 2 != 0) != nil
            && PixArt3395SE.read(record[1], high: record[2] & 32 != 0) != nil
    }

    private static func pairAddress(base: Int, index: Int) -> Int {
        base + 8 * (index / 2)
    }

    private static func readRecords(base: Int, count: Int, mouse: Compx) throws -> [[UInt8]] {
        var records: [[UInt8]] = []
        for index in stride(from: 0, to: count, by: 2) {
            let bytes = try mouse.read(pairAddress(base: base, index: index), 8)
            records.append(Array(bytes[0..<4]))
            records.append(Array(bytes[4..<8]))
        }
        return records
    }

    private static func write(_ blocks: [Block], mouse: Compx) throws {
        var attempted: [Block] = []
        do {
            for block in blocks where block.previous != block.next {
                attempted.append(block)
                try mouse.write(block.address, block.next, replacing: block.previous)
            }
        } catch {
            var restored = true
            for block in attempted.reversed() {
                do {
                    let current = try mouse.read(block.address, block.next.count)
                    if current == block.next {
                        try mouse.write(block.address, block.previous, replacing: block.next)
                    } else if current != block.previous {
                        restored = false
                    }
                } catch {
                    restored = false
                }
            }
            if !restored {
                throw MouseError.unavailable("The stage changed only partially. Refresh to check the settings on the mouse.")
            }
            throw error
        }
    }
}
