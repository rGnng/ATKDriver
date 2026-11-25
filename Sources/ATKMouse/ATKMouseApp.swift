import AppKit
import SwiftUI
import ATKMouseCore

@main
struct ATKApp: App {
    var body: some Scene {
        Window("ATK", id: "mouse") {
            MouseWindow()
        }
        .defaultSize(width: 852, height: 568)
    }
}

@MainActor @Observable
private final class MouseWindowModel {
    var devices: [MouseDevice] = []
    var selection: UInt64?
    var snapshot: MouseSnapshot?
    var busy = false
    var error: String?
    var permissionRequired = false
    var permissionRequested = false

    var device: MouseDevice? { devices.first { $0.id == selection } }

    func discover(force: Bool = false) async {
        guard !busy else { return }
        let devices = await Task.detached { MouseService.devices() }.value
        guard !busy else { return }
        let oldSelection = selection
        if self.devices != devices { self.devices = devices }
        if !devices.contains(where: { $0.id == selection }) {
            selection = (devices.first(where: \.supportsConfiguration) ?? devices.first)?.id
        }
        if force || oldSelection != selection {
            snapshot = nil
            await load()
        }
    }

    func requestPermission() async {
        guard permissionRequired, !busy else { return }
        let granted = MouseService.requestInputAccess()
        permissionRequested = true
        if granted { await load() }
    }

    func retryAfterPermission() async {
        if permissionRequired && MouseService.hasInputAccess() { await load() }
    }

    func select(_ id: UInt64?) async {
        guard !busy, let id, selection != id, devices.contains(where: { $0.id == id }) else { return }
        selection = id
        snapshot = nil
        await load()
    }

    func load(_ change: MouseChange? = nil) async {
        guard !busy else { return }
        error = nil
        permissionRequired = false
        guard let device, device.supportsConfiguration else { return }
        if device.sharesKeyboardInterface == true && !MouseService.hasInputAccess() {
            permissionRequired = true
            return
        }
        busy = true
        defer { busy = false }
        let profile = snapshot?.profile
        do {
            snapshot = try await Task.detached(priority: .userInitiated) {
                if let change { try MouseService.apply(change, to: device, expectedProfile: profile) }
                return try MouseService.read(device)
            }.value
        } catch {
            self.error = error.localizedDescription
            if case MouseError.permission = error { permissionRequired = true }
            if change != nil {
                snapshot = await Task.detached { try? MouseService.read(device) }.value
            }
        }
    }
}

private struct MouseWindow: View {
    @State private var model = MouseWindowModel()
    @State private var showingDetails = false

    var body: some View {
        Group {
            if let state = model.snapshot {
                DeviceForm(state: state, issue: model.error, busy: model.busy, change: apply)
                    .id(state.device.id)
            } else {
                emptyState
            }
        }
        .frame(minWidth: 760, minHeight: 508)
        .background { WindowTextEditing().allowsHitTesting(false) }
        .toolbar {
            ToolbarItem(placement: .principal) {
                devicePicker
            }
            ToolbarItem {
                Button {
                    showingDetails.toggle()
                } label: {
                    Label("Device Details", systemImage: "info.circle")
                }
                .help("Device details")
                .disabled(model.device == nil)
                .popover(isPresented: $showingDetails, arrowEdge: .top) {
                    if let device = model.device {
                        DeviceDetails(device: device, snapshot: model.snapshot)
                    }
                }
            }
            ToolbarItem {
                Button {
                    Task { await model.discover(force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.busy)
            }
        }
        .onChange(of: model.selection) { _, _ in showingDetails = false }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await model.retryAfterPermission() }
        }
        .task {
            while !Task.isCancelled {
                await model.discover()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var devicePicker: some View {
        let labels = MouseDevice.chooserLabels(for: model.devices)
        let selectedTitle = model.device.map { labels[$0.id] ?? $0.name } ?? "No mouse connected"
        return Menu {
            ForEach(model.devices) { device in
                Button {
                    Task { await model.select(device.id) }
                } label: {
                    let title = labels[device.id] ?? device.name
                    if device.id == model.selection {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "computermouse")
                Text(selectedTitle)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: 275)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("Connected mice")
        .accessibilityValue(selectedTitle)
        .help("Choose a connected mouse")
        .disabled(model.devices.isEmpty || model.busy)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            if model.busy {
                ProgressView("Reading mouse settings…")
            } else if let device = model.device {
                ContentUnavailableView {
                    Label(device.name, systemImage: "computermouse")
                } description: {
                    if model.permissionRequired {
                        Text("macOS requires Input Monitoring to read this mouse’s settings. Request access, then enable ATK in System Settings.")
                    } else {
                        Text(model.error ?? "Settings are unavailable on this connection. Connect the mouse by USB or through its receiver.")
                    }
                } actions: {
                    if model.permissionRequired {
                        if model.permissionRequested {
                            Button("Open Input Monitoring") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        } else {
                            Button("Request Input Monitoring") {
                                Task { await model.requestPermission() }
                            }
                        }
                    } else if device.supportsConfiguration {
                        Button("Try Again") { Task { await model.load() } }
                    }
                }
            } else {
                ContentUnavailableView("Connect a Mouse", systemImage: "computermouse", description:
                    Text("Connect your ATK or VXE mouse by USB or through its receiver."))
            }
        }
        .padding(24)
    }

    private func apply(_ change: MouseChange) {
        Task { await model.load(change) }
    }
}

private struct DeviceDetails: View {
    let device: MouseDevice
    let snapshot: MouseSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(device.name)
                .font(.headline)
                .accessibilityAddTraits(.isHeader)

            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 8) {
                detail("Connection", device.link.rawValue)
                detail(device.link == .receiver ? "Receiver serial number" : "Serial number",
                       device.serialNumber ?? "Unavailable", monospaced: true)
                detail(device.link == .bluetooth ? "Vendor / Product ID" : "USB VID / PID",
                       device.usbID.uppercased(), monospaced: true)

                if device.link != .bluetooth, let port = device.port {
                    detail("USB location", port, monospaced: true)
                }
                if let revision = device.revision {
                    detail("USB revision", revision)
                }
                if let snapshot {
                    detail("Model code", "\(snapshot.company) / \(snapshot.model)", monospaced: true)
                    if let uid = snapshot.deviceUID {
                        detail("Device UID", uid, monospaced: true)
                    }
                    if let firmware = snapshot.firmware {
                        detail("Firmware", firmware)
                    }
                    if let battery = snapshot.battery {
                        detail("Battery", "\(battery)%\(snapshot.charging == true ? " (Charging)" : "")")
                    }
                    if let voltage = snapshot.batteryMillivolts {
                        detail("Battery voltage", (Double(voltage) / 1000).formatted(.number.precision(.fractionLength(2))) + " V")
                    }
                }
            }
            .font(.callout)
        }
        .padding(16)
        .frame(minWidth: 298, idealWidth: 330, maxWidth: 450, alignment: .leading)
    }

    private func detail(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
                .fontDesign(monospaced ? .monospaced : .default)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct DeviceForm: View {
    let state: MouseSnapshot
    let issue: String?
    let busy: Bool
    let change: (MouseChange) -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let issue {
                    Label(issue, systemImage: "exclamationmark.circle")
                        .font(.callout)
                        .padding(.horizontal, 4)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(spacing: 14) {
                        SettingsCard("Sensitivity", icon: "cursorarrow.motionlines") {
                            if state.writable {
                                DPIEditor(stages: state.stages, activeStage: state.activeStage, change: change)
                                    .id(state.profile)
                            } else {
                                LabeledContent("Active stage", value: String(state.activeStage))
                            }
                        }
                        SettingsCard("Performance", icon: "speedometer") {
                            controlRow("Polling rate") {
                                Picker("Polling rate", selection: Binding(get: { state.pollingRate }, set: { change(.rate($0)) })) {
                                    ForEach(state.pollingRates, id: \.self) { Text("\($0) Hz").tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 112)
                            }
                            if let profile = state.profile {
                                controlRow("Onboard profile") {
                                    Picker("Onboard profile", selection: Binding(get: { profile }, set: { change(.profile($0)) })) {
                                        ForEach(1...4, id: \.self) { Text("Profile \($0)").tag($0) }
                                    }
                                    .labelsHidden()
                                    .frame(width: 112)
                                }
                            }
                        }
                        .disabled(!state.writable)
                    }
                    .frame(maxWidth: .infinity)
                    if !state.settings.isEmpty || !state.buttons.isEmpty {
                        VStack(spacing: 14) {
                            if !state.settings.isEmpty {
                                SettingsCard("Sensor", icon: "scope") { sensorControls }
                            }
                            if !state.buttons.isEmpty {
                                SettingsCard("Buttons", icon: "computermouse") { buttonControls }
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 13)
            .padding(.bottom, 16)
            .frame(maxWidth: 1060)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .disabled(busy)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "computermouse.fill")
                .font(.title2.weight(.medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.device.name)
                    .font(.title3.weight(.semibold))
                Text(state.writable ? state.device.link.rawValue : "\(state.device.link.rawValue) (Read only)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if busy {
                ProgressView().controlSize(.small).accessibilityLabel("Updating mouse")
            }
            if let version = state.firmware {
                headerDetail("Firmware", value: version)
            }
            if let battery = state.battery {
                headerDetail("Battery", value: "\(battery)%", icon: state.charging == true ? "bolt.fill" : nil)
            }
        }
        .padding(.horizontal, 2)
        .padding(.vertical, 2)
    }

    private func headerDetail(_ label: String, value: String, icon: String? = nil) -> some View {
        VStack(alignment: .trailing, spacing: 2) {
            HStack(spacing: 4) {
                if let icon {
                    Image(systemName: icon).font(.caption).accessibilityLabel("Charging")
                }
                Text(value).font(.callout.monospacedDigit().weight(.semibold))
            }
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var sensorControls: some View {
        let switches: [MouseSetting] = [.motionSync, .angleSnap, .rippleControl]
        return VStack(alignment: .leading, spacing: 4) {
            forEachSetting([.liftOff, .debounce, .sleep, .performance])
            if switches.contains(where: { state.settings[$0] != nil }) {
                Divider().padding(.vertical, 4)
                HStack(spacing: 10) {
                    ForEach(switches, id: \.self) { setting in
                        if let value = state.settings[setting] {
                            Toggle(setting.label, isOn: Binding(
                                get: { value == 1 }, set: { change(.setting(setting, $0 ? 1 : 0)) }
                            ))
                            .toggleStyle(.checkbox)
                            .controlSize(.small)
                            .fixedSize()
                        }
                    }
                }
                .frame(minHeight: 24)
            }
        }
    }

    private func forEachSetting(_ settings: [MouseSetting]) -> some View {
        ForEach(settings, id: \.self) { setting in
            if let value = state.settings[setting] {
                controlRow(setting.label) {
                    Picker(setting.label, selection: Binding(get: { value }, set: { change(.setting(setting, $0)) })) {
                        if !setting.choices.contains(value) {
                            Text(setting == .performance ? "Current (\(value))" : setting.description(of: value)).tag(value)
                        }
                        ForEach(setting.choices, id: \.self) { Text(setting.description(of: $0)).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 120)
                }
            }
        }
    }

    private var buttonControls: some View {
        VStack(spacing: 4) {
            ForEach(MouseButton.allCases.filter { $0 != .left }, id: \.self) { button in
                if let value = state.buttons[button] {
                    controlRow(button.label) {
                        Picker(button.label, selection: Binding(get: { value }, set: { change(.button(button, $0)) })) {
                            ForEach(ButtonAction.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 120)
                    }
                }
            }
        }
    }
}

private struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder let content: Content

    init(_ title: String, icon: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.icon = icon
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: icon)
                .font(.headline)
                .labelStyle(.titleAndIcon)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.55), lineWidth: 1)
                .allowsHitTesting(false)
        }
    }
}

private func controlRow<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
    HStack(spacing: 8) {
        Text(title)
        Spacer(minLength: 6)
        control()
    }
    .frame(minHeight: 25)
}

private struct DPIEditor: View {
    let stages: [DPIStage]
    let activeStage: Int
    let change: (MouseChange) -> Void
    @State private var selection: Int
    @State private var x = ""
    @State private var y = ""
    @State private var separate = false
    @State private var confirmingRemoval = false
    @FocusState private var keyboardFocus: FocusTarget?

    private enum FocusTarget: Hashable {
        case stages, horizontal, vertical
    }

    init(stages: [DPIStage], activeStage: Int, change: @escaping (MouseChange) -> Void) {
        self.stages = stages
        self.activeStage = activeStage
        self.change = change
        _selection = State(initialValue: activeStage)
    }

    private var stage: DPIStage? { stages.first { $0.id == selection } }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Picker("DPI stage", selection: $selection) {
                    ForEach(stages) { stage in
                        Text(stages.count <= 4 ? "Stage \(stage.id)" : "\(stage.id)").tag(stage.id)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .focusable()
                .focused($keyboardFocus, equals: .stages)

                ControlGroup {
                    Button("Add DPI Stage", systemImage: "plus") { change(.addStage) }
                        .help("Add DPI stage")
                        .disabled(stages.count >= MouseService.maximumDPIStages)
                    Button("Remove DPI Stage", systemImage: "minus") { confirmingRemoval = true }
                        .help("Remove selected DPI stage")
                        .disabled(stages.count <= 1)
                }
                .labelStyle(.iconOnly)
                .fixedSize()
            }

            HStack(spacing: 6) {
                Label(selection == activeStage ? "Active" : "Inactive",
                      systemImage: selection == activeStage ? "circle.inset.filled" : "circle")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Toggle("Separate X and Y", isOn: $separate)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
            }

            HStack(spacing: 8) {
                dpiField(separate ? "Horizontal" : "DPI", value: $x, focus: .horizontal)
                if separate { dpiField("Vertical", value: $y, focus: .vertical) }
            }

            HStack {
                Button("Set Active") { change(.stage(selection)) }
                    .disabled(selection == activeStage)
                Spacer()
                Button("Apply DPI") {
                    keyboardFocus = nil
                    if let horizontal = Int(x), let vertical = Int(separate ? y : x) {
                        change(.dpi(stage: selection, x: horizontal, y: vertical))
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!hasChange)
            }
        }
        .defaultFocus($keyboardFocus, .stages)
        .onSubmit { keyboardFocus = nil }
        .alert("Remove Stage \(selection)?", isPresented: $confirmingRemoval) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) { change(.removeStage(selection)) }
        }
        .onChange(of: stages.count) { oldCount, count in
            selection = count > oldCount ? count : min(selection, count)
        }
        .onChange(of: selection, initial: true) { _, _ in loadStage() }
        .onChange(of: stage?.x) { _, _ in loadStage() }
        .onChange(of: stage?.y) { _, _ in loadStage() }
    }

    private func dpiField(_ label: String, value: Binding<String>, focus: FocusTarget) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
            TextField(label, text: value)
                .focused($keyboardFocus, equals: focus)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(minWidth: 54)
        }
        .frame(maxWidth: .infinity)
    }

    private var hasChange: Bool {
        guard let stage, let horizontal = Int(x), let vertical = Int(separate ? y : x) else { return false }
        return horizontal != stage.x || vertical != stage.y
    }

    private func loadStage() {
        x = stage?.x.map(String.init) ?? ""
        y = stage?.y.map(String.init) ?? ""
        separate = stage?.x != stage?.y
    }
}
