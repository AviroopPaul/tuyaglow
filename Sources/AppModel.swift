import AppKit
import Foundation
import Security

enum Keychain {
    static let service = "site.aviroop.tuyaglow"

    static func get(_ account: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ account: String, _ value: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var mode: Mode = .off { didSet { if mode != oldValue { modeChanged(from: oldValue) } } }
    @Published var intense = false { didSet { pushConfig() } }
    @Published var paletteName = UserDefaults.standard.string(forKey: "palette") ?? "Neon" {
        didSet { UserDefaults.standard.set(paletteName, forKey: "palette"); pushConfig() }
    }
    @Published var ceiling = UserDefaults.standard.object(forKey: "ceiling") as? Double ?? 1 {
        didSet { UserDefaults.standard.set(ceiling, forKey: "ceiling"); pushConfig() }
    }
    @Published var status = "Not connected"
    @Published var connected = false
    @Published var error: String?
    @Published var needsPermission = false
    @Published var musicInfo = ""

    // Light mode: a normal bulb, white shades or a picked color.
    enum LightKind: String, CaseIterable { case white = "White", color = "Color" }
    @Published var lightKind = LightKind(rawValue: UserDefaults.standard.string(forKey: "lightKind") ?? "") ?? .white { didSet { lightChanged() } }
    @Published var lightPower = true { didSet { lightChanged() } }
    @Published var lightBrightness = UserDefaults.standard.object(forKey: "lightBrightness") as? Double ?? 0.8 { didSet { lightChanged() } }
    /// 0 = warmest, 1 = coolest.
    @Published var lightWarmth = UserDefaults.standard.object(forKey: "lightWarmth") as? Double ?? 0.3 { didSet { lightChanged() } }
    @Published var lightHue = UserDefaults.standard.object(forKey: "lightHue") as? Double ?? 30 { didSet { lightChanged() } }
    @Published var lightSaturation = UserDefaults.standard.object(forKey: "lightSaturation") as? Double ?? 1 { didSet { lightChanged() } }
    private var lightSendPending = false
    private var lastLightSend = Date.distantPast
    private var infoBPM = 0.0, infoLocked = false, infoSection = Section.silent
    /// 0 = follow the active window's display; otherwise a CGDirectDisplayID.
    @Published var displayChoice: UInt32 = UInt32(UserDefaults.standard.integer(forKey: "display")) {
        didSet { UserDefaults.standard.set(Int(displayChoice), forKey: "display"); if mode == .screen { startCapture() } }
    }
    private var followTimer: Timer?

    var displays: [(id: UInt32, name: String)] {
        NSScreen.screens.compactMap { s in
            guard let n = s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return (n.uint32Value, "\(s.localizedName) (\(Int(s.frame.width))x\(Int(s.frame.height)))")
        }
    }

    @Published var deviceID = UserDefaults.standard.string(forKey: "deviceID") ?? ""
    @Published var ip = UserDefaults.standard.string(forKey: "ip") ?? ""
    @Published var localKey = Keychain.get("localKey") ?? ""
    @Published var version = UserDefaults.standard.string(forKey: "version") ?? "3.5"
    @Published var scanResults: [TuyaDiscovery.Found] = []
    @Published var scanning = false
    static let versions = ["3.3", "3.4", "3.5"]

    private var client: TuyaClient?
    private let engine = LightEngine()
    private let capture = Capture()
    private var detector = BeatDetector()
    private var saved: [String: Any]?
    private var discovering = false

    var palette: Palette { Palette.all.first { $0.name == paletteName } ?? Palette.all[0] }
    var hasSettings: Bool { !deviceID.isEmpty && !ip.isEmpty && localKey.count == 16 }
    static let helpURL = URL(string: "https://github.com/AviroopPaul/tuyaglow#2-get-your-bulbs-device-id-and-local-key")!

    init() {
        capture.onColor = { [engine] r, g, b, l in engine.handleScreen(r: r, g: g, b: b, lum: l) }
        capture.onError = { [weak self] msg in Task { @MainActor in self?.captureFailed(msg) } }
    }

    // MARK: settings

    func saveSettings() {
        let d = UserDefaults.standard
        d.set(deviceID.trimmingCharacters(in: .whitespaces), forKey: "deviceID")
        d.set(ip.trimmingCharacters(in: .whitespaces), forKey: "ip")
        d.set(version, forKey: "version")
        localKey = localKey.trimmingCharacters(in: .whitespacesAndNewlines)
        Keychain.set("localKey", localKey)
        error = localKey.count == 16 || localKey.isEmpty ? nil : "A Tuya local key is 16 characters long"
        rebuildClient()
    }

    /// Listen for Tuya broadcasts. With a device ID set, fills in its IP and version;
    /// otherwise lists every Tuya device found so the user can pick one.
    func findOnWiFi() {
        guard !scanning else { return }
        scanning = true
        error = nil
        status = "Scanning Wi-Fi"
        let id = deviceID.trimmingCharacters(in: .whitespaces)
        let done: (Set<TuyaDiscovery.Found>) -> Void = { all in
            Task { @MainActor in
                self.scanning = false
                self.scanResults = all.sorted { $0.ip < $1.ip }
                if let me = all.first(where: { $0.id == id }) {
                    self.use(me)
                    self.status = "Found at \(me.ip)"
                } else {
                    self.status = all.isEmpty ? "No Tuya devices found" : "Found \(all.count) device(s)"
                    if !id.isEmpty, !all.isEmpty { self.error = "Your device ID was not in the scan. Check it, or pick a device below." }
                }
            }
        }
        if id.isEmpty {
            TuyaDiscovery.scan(timeout: 8, done)
        } else {
            TuyaDiscovery.scan(timeout: 12, stop: { $0.contains { $0.id == id } }, done)
        }
    }

    /// Fill settings from a scan result (keeps the local key).
    func use(_ f: TuyaDiscovery.Found) {
        deviceID = f.id
        ip = f.ip
        if Self.versions.contains(f.version) { version = f.version }
        let d = UserDefaults.standard
        d.set(f.id, forKey: "deviceID"); d.set(f.ip, forKey: "ip"); d.set(version, forKey: "version")
        if let c = client, c.deviceID == f.id, c.version == Double(version) { c.setHost(f.ip) } else { rebuildClient() }
    }

    private func rebuildClient() {
        let wasOn = mode != .off
        client?.stop()
        client = nil
        engine.attach(nil)
        connected = false
        status = "Not connected"
        if wasOn { mode = .off }
    }

    private func makeClient() -> TuyaClient? {
        if let client { return client }
        guard hasSettings else { error = "Open Bulb settings and add your bulb's device ID, local key and IP"; return nil }
        let c = TuyaClient(deviceID: deviceID, host: ip, localKey: localKey, version: Double(version) ?? 3.5)
        var failures = 0
        c.onState = { [weak self] st in
            Task { @MainActor in
                guard let self else { return }
                switch st {
                case .ready: self.connected = true; self.status = "Connected"; failures = 0
                case .connecting: self.connected = false; self.status = "Connecting"
                case .idle: self.connected = false; self.status = "Not connected"
                case .failed(let why):
                    self.connected = false
                    self.status = why.contains("key") ? "Check key and version" : "Reconnecting"
                    failures += 1
                    if failures == 2, !self.deviceID.isEmpty { self.findOnWiFi() }
                }
            }
        }
        client = c
        engine.attach(c)
        return c
    }

    // MARK: start / stop

    private func modeChanged(from old: Mode) {
        blog(String(format: "mode %@ -> %@", old.rawValue, mode.rawValue))
        error = nil
        if mode == .off { stopAll(keepLight: old == .light); return }
        guard let c = makeClient() else { mode = .off; return }
        let synced = mode == .music || mode == .screen
        // Remember the bulb's state when a sync mode starts, so Off can put it back.
        let needsSave = synced && (old == .off || old == .light)
        let begin = {
            if self.mode == .light {
                self.stopSync()
                self.saved = nil   // the user is setting the light by hand now
                self.sendLight()
                return
            }
            guard needsSave else { self.pushConfig(); self.startCapture(); return }
            c.queryStatus { dps in
                Task { @MainActor in
                    self.saved = dps
                    c.send(dps: ["20": true, "21": "colour"])
                    self.pushConfig()
                    self.startCapture()
                }
            }
        }
        if old == .off {
            c.start()
            waitReady(c) { ok in
                guard ok else {
                    self.error = "Could not reach the bulb. Check the IP and protocol version, or try Find on Wi-Fi."
                    self.mode = .off
                    return
                }
                // 3.3 bulbs accept the connection even with a wrong key, so ask for status to be sure.
                c.queryStatus { dps in
                    if dps == nil {
                        Task { @MainActor in self.error = "The bulb did not answer. Check the local key and protocol version." }
                    }
                }
                begin()
            }
        } else {
            begin()
        }
    }

    // MARK: light mode

    private func lightChanged() {
        let d = UserDefaults.standard
        d.set(lightKind.rawValue, forKey: "lightKind")
        d.set(lightBrightness, forKey: "lightBrightness")
        d.set(lightWarmth, forKey: "lightWarmth")
        d.set(lightHue, forKey: "lightHue")
        d.set(lightSaturation, forKey: "lightSaturation")
        guard mode == .light else { return }
        // Coalesce slider drags to at most ~10 writes a second.
        let wait = 0.1 - Date().timeIntervalSince(lastLightSend)
        if wait <= 0 { sendLight(); return }
        guard !lightSendPending else { return }
        lightSendPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
            self.lightSendPending = false
            if self.mode == .light { self.sendLight() }
        }
    }

    private func sendLight() {
        guard let c = client else { return }
        lastLightSend = Date()
        var dps: [String: Any] = ["20": lightPower]
        if lightPower {
            switch lightKind {
            case .white:
                dps["21"] = "white"
                dps["22"] = Int(10 + 990 * lightBrightness)
                dps["23"] = Int(1000 * lightWarmth)
            case .color:
                dps["21"] = "colour"
                dps["24"] = String(format: "%04x%04x%04x", Int(lightHue) % 360, Int(1000 * lightSaturation), Int(10 + 990 * lightBrightness))
            }
        }
        c.send(dps: dps)
    }

    func setLightColor(_ color: NSColor) {
        guard let c = color.usingColorSpace(.deviceRGB) else { return }
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        lightKind = .color
        lightHue = Double(h) * 360
        lightSaturation = Double(s)
    }

    var lightColor: NSColor {
        lightKind == .white
            ? NSColor(calibratedRed: 1, green: 0.82 + 0.18 * lightWarmth, blue: 0.6 + 0.4 * lightWarmth, alpha: 1)
            : NSColor(hue: lightHue / 360, saturation: lightSaturation, brightness: 1, alpha: 1)
    }

    private func waitReady(_ c: TuyaClient, tries: Int = 60, _ done: @escaping (Bool) -> Void) {
        if c.isReady { done(true); return }
        if tries == 0 { done(false); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { self.waitReady(c, tries: tries - 1, done) }
    }

    private func startCapture() {
        let fps = mode == .screen ? 15 : 1
        let det = BeatDetector()
        det.onEvent = { [engine, weak self] e in
            engine.handle(e)
            switch e {
            case .tempo, .section, .drop: Task { @MainActor in self?.noteMusic(e) }
            default: break
            }
        }
        detector = det
        capture.onAudio = { [det] s, _ in det.process(s) }
        followTimer?.invalidate(); followTimer = nil
        if mode == .screen && displayChoice == 0 {
            // Follow the active window to whichever display it is on.
            followTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.mode == .screen, self.displayChoice == 0,
                          let want = Capture.activeDisplayID(), let cur = self.capture.displayID, want != cur else { return }
                    blog("following active window to display \(want)")
                    self.startCapture()
                }
            }
        }
        Task {
            do {
                try await capture.start(videoFPS: fps, display: displayChoice == 0 ? nil : displayChoice)
                blog(String(format: "capture started fps=%d", fps))
                needsPermission = false
            } catch {
                captureFailed(error.localizedDescription)
            }
        }
    }

    private func noteMusic(_ e: BeatDetector.Event) {
        switch e {
        case .tempo(let b, let l): infoBPM = b; infoLocked = l
        case .section(let s): infoSection = s; blog("section \(s.rawValue)")
        case .drop: blog("DROP")
        default: break
        }
        var bpm = infoBPM
        if bpm > 145 { bpm /= 2 }   // shown and played in half-time
        let tempo = infoLocked && bpm > 0 ? "\(Int(bpm.rounded())) BPM" : "Finding the beat"
        musicInfo = "\(tempo), \(infoSection.rawValue)"
    }

    private func captureFailed(_ msg: String) {
        blog(String(format: "capture failed: %@", msg))
        needsPermission = !CGPreflightScreenCaptureAccess()
        error = needsPermission ? "TuyaGlow needs Screen Recording permission to hear and see your Mac" : "Capture stopped: \(msg)"
        if mode != .off { mode = .off }
    }

    /// Stop capture and the light engine (used for Off and for Light mode).
    private func stopSync() {
        engine.configure(mode: .off, intense: intense, palette: palette, ceiling: Float(ceiling))
        followTimer?.invalidate(); followTimer = nil
        musicInfo = ""
        Task { await capture.stop() }
    }

    private func stopAll(keepLight: Bool) {
        stopSync()
        if keepLight {
            // Off after Light leaves the bulb as you set it.
            saved = nil
            let c = client
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { if self.mode == .off { c?.stop() } }
        } else {
            restoreBulb(blocking: false)
        }
    }

    func restoreBulb(blocking: Bool) {
        guard let c = client else { return }
        if let s = saved {
            var r: [String: Any] = [:]
            for k in ["21", "22", "23", "24", "20"] { if let v = s[k] { r[k] = v } }
            if blocking { c.sendAndFlush(dps: r) } else { c.send(dps: r) }
        }
        saved = nil
        if !blocking {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                if self.mode == .off { c.stop() }
            }
        }
    }

    private func pushConfig() {
        engine.configure(mode: mode, intense: intense, palette: palette, ceiling: Float(ceiling))
    }

    func openPermissionSettings() {
        CGRequestScreenCaptureAccess()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func quit() {
        if mode == .music || mode == .screen {
            Task { await capture.stop() }
            restoreBulb(blocking: true)
        }
        NSApp.terminate(nil)
    }
}
