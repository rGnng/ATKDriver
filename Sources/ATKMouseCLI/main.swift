import Darwin
import Foundation
import ATKMouseCore

func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    print(String(decoding: try encoder.encode(value), as: UTF8.self))
}

func parseChange(_ args: [String]) throws -> MouseChange {
    if args == ["add-stage"] { return .addStage }
    if args.count == 2, let value = Int(args[1]) {
        switch args[0] {
        case "rate": return .rate(value)
        case "stage": return .stage(value)
        case "remove-stage": return .removeStage(value)
        case "profile": return .profile(value)
        default: break
        }
    }
    if args.count == 4, args[0] == "dpi", let stage = Int(args[1]), let x = Int(args[2]), let y = Int(args[3]) {
        return .dpi(stage: stage, x: x, y: y)
    }
    if args.count == 3, args[0] == "setting", let key = MouseSetting(rawValue: args[1]), let value = Int(args[2]) {
        return .setting(key, value)
    }
    if args.count == 3, args[0] == "button", let button = MouseButton(rawValue: args[1]),
       let action = ButtonAction(rawValue: args[2]) {
        return .button(button, action)
    }
    throw MouseError.unavailable("Unknown command. Run atk-cli --help.")
}

var args = Array(CommandLine.arguments.dropFirst())
do {
    if args.isEmpty || args == ["--help"] {
        print("""
        Usage: atk-cli [--device REGISTRY-ID] COMMAND
          list
          status
          rate HZ
          stage NUMBER
          add-stage
          remove-stage NUMBER
          dpi STAGE X Y
          profile NUMBER
          setting NAME VALUE
          button BUTTON ACTION
        """)
        exit(0)
    }
    let devices = MouseService.devices()
    if args == ["list"] {
        try printJSON(devices)
        exit(0)
    }
    let device: MouseDevice
    if args.first == "--device", args.count >= 3, let id = UInt64(args[1]) {
        guard let selected = devices.first(where: { $0.id == id }) else {
            throw MouseError.unavailable("The selected device isn’t connected.")
        }
        device = selected
        args.removeFirst(2)
    } else {
        guard devices.count == 1, let selected = devices.first else {
            throw MouseError.unavailable(devices.isEmpty ? "No ATK or VXE mouse connected." : "Choose a device using atk-cli list and --device.")
        }
        device = selected
    }
    if args != ["status"] {
        try MouseService.apply(parseChange(args), to: device)
    }
    try printJSON(MouseService.read(device))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
