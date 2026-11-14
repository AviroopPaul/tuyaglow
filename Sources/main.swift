import AppKit
import SwiftUI

struct PanelView: View {
    @ObservedObject var m: AppModel
    @State private var showSettings = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("TuyaGlow").font(.headline)
                Spacer()
                Circle().fill(m.connected ? Color.green : Color.secondary.opacity(0.5)).frame(width: 8, height: 8)
                Text(m.status).font(.caption).foregroundStyle(.secondary)
            }

            Picker("", selection: $m.mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if m.mode == .music, !m.musicInfo.isEmpty {
                Text(m.musicInfo).font(.caption).foregroundStyle(.secondary)
            }

            if m.mode == .light {
                LightPanel(m: m)
            }

            if m.mode == .music || m.mode == .off {
                Toggle(isOn: $m.intense) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Intense")
                        Text("Also flashes on hi-hats, up to 20 times a second").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Picker("Colors", selection: $m.paletteName) {
                    ForEach(Palette.all) { Text($0.name).tag($0.name) }
                }
            }

            if m.mode == .screen {
                Picker("Display", selection: $m.displayChoice) {
                    Text("Follow active window").tag(UInt32(0))
                    ForEach(m.displays, id: \.id) { d in Text(d.name).tag(d.id) }
                }
            }

            if m.mode != .light {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Max brightness: \(Int(m.ceiling * 100))%").font(.caption)
                    Slider(value: $m.ceiling, in: 0.1...1)
                }
            }

            if let e = m.error {
                Text(e).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                if m.needsPermission {
                    Button("Open Screen Recording settings") { m.openPermissionSettings() }
                }
            }

            Divider()

            DisclosureGroup("Bulb settings", isExpanded: $showSettings) {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("Device ID", text: $m.deviceID)
                    SecureField("Local key (16 characters)", text: $m.localKey)
                    HStack {
                        TextField("IP address", text: $m.ip)
                        Picker("", selection: $m.version) {
                            ForEach(AppModel.versions, id: \.self) { Text("v\($0)").tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 70)
                        .help("Tuya protocol version. Find on Wi-Fi fills this in.")
                    }
                    HStack {
                        Button("Save") { m.saveSettings() }
                        Button(m.scanning ? "Scanning..." : "Find on Wi-Fi") { m.findOnWiFi() }
                            .disabled(m.scanning)
                            .help("Listens for Tuya bulbs on your network and fills in IP and version")
                    }
                    if m.scanResults.contains(where: { $0.id != m.deviceID }) {
                        Text("Found on Wi-Fi (click to use):").font(.caption).foregroundStyle(.secondary)
                        ForEach(m.scanResults, id: \.self) { f in
                            Button { m.use(f) } label: {
                                Text("\(f.ip)  v\(f.version)  \(f.id)").font(.caption.monospaced()).lineLimit(1).truncationMode(.middle)
                            }
                            .buttonStyle(.link)
                        }
                    }
                    Link("How do I get the device ID and local key?", destination: AppModel.helpURL).font(.caption)
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 4)
            }
            .font(.callout)

            HStack {
                Spacer()
                Button("Quit") { m.quit() }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}

struct LightPanel: View {
    @ObservedObject var m: AppModel

    private let whites: [(String, Double)] = [("Candle", 0), ("Warm", 0.25), ("Neutral", 0.5), ("Daylight", 0.75), ("Cool", 1)]
    private let colors: [Double] = [0, 25, 50, 120, 180, 220, 270, 310]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Toggle("Power", isOn: $m.lightPower)
                Spacer()
                Picker("", selection: $m.lightKind) {
                    ForEach(AppModel.LightKind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 140)
            }

            if m.lightKind == .white {
                HStack(spacing: 6) {
                    ForEach(whites, id: \.0) { name, w in
                        Button { m.lightWarmth = w } label: {
                            VStack(spacing: 3) {
                                Circle()
                                    .fill(Color(nsColor: NSColor(calibratedRed: 1, green: 0.82 + 0.18 * w, blue: 0.6 + 0.4 * w, alpha: 1)))
                                    .overlay(Circle().stroke(abs(m.lightWarmth - w) < 0.01 ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: 2))
                                    .frame(width: 26, height: 26)
                                Text(name).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                HStack {
                    Text("Warm").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $m.lightWarmth, in: 0...1)
                    Text("Cool").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 6) {
                    ForEach(colors, id: \.self) { h in
                        Button { m.lightHue = h; m.lightSaturation = 1 } label: {
                            Circle()
                                .fill(Color(hue: h / 360, saturation: 1, brightness: 1))
                                .overlay(Circle().stroke(abs(m.lightHue - h) < 1 && m.lightSaturation > 0.95 ? Color.primary : Color.clear, lineWidth: 2))
                                .frame(width: 24, height: 24)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity)
                    }
                }
                ColorPicker("Custom color", selection: Binding(
                    get: { Color(nsColor: m.lightColor) },
                    set: { m.setLightColor(NSColor($0)) }
                ), supportsOpacity: false)
                HStack {
                    Text("Pale").font(.caption2).foregroundStyle(.secondary)
                    Slider(value: $m.lightSaturation, in: 0.05...1)
                    Text("Vivid").font(.caption2).foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Brightness: \(Int(m.lightBrightness * 100))%").font(.caption)
                Slider(value: $m.lightBrightness, in: 0.01...1)
            }
        }
        .disabled(!m.connected && m.mode == .light)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    var item: NSStatusItem!
    let popover = NSPopover()
    var sub: Any?

    func applicationDidFinishLaunching(_ n: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateIcon()
        item.button?.target = self
        item.button?.action = #selector(toggle)
        popover.behavior = .semitransient   // stays open while the color panel is used
        popover.contentViewController = NSHostingController(rootView: PanelView(m: model))
        // Debug / scripting: `open TuyaGlow.app --args -startMode Music`
        if let m = UserDefaults.standard.string(forKey: "startMode"), let mode = Mode(rawValue: m) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.model.mode = mode }
        }
        sub = model.$mode.sink { [weak self] _ in DispatchQueue.main.async { self?.updateIcon() } }
    }

    func updateIcon() {
        let on = model.mode != .off
        let img = NSImage(systemSymbolName: on ? "lightbulb.fill" : "lightbulb", accessibilityDescription: "TuyaGlow")
        img?.isTemplate = true
        item.button?.image = img
    }

    @objc func toggle() {
        guard let b = item.button else { return }
        if popover.isShown { popover.performClose(nil) } else {
            popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        if model.mode == .music || model.mode == .screen { model.restoreBulb(blocking: true) }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
