import Foundation

enum Mode: String, CaseIterable, Identifiable {
    case off = "Off", light = "Light", music = "Music", screen = "Screen"
    var id: String { rawValue }
}

struct Palette: Identifiable, Hashable {
    let name: String
    let hues: [Int]   // 0...359
    var id: String { name }
    static let all: [Palette] = [
        Palette(name: "Neon", hues: [300, 190, 60, 330, 140, 260]),
        Palette(name: "Warm", hues: [0, 20, 35, 50, 345, 10]),
        Palette(name: "Ocean", hues: [190, 210, 170, 230, 160, 200]),
        Palette(name: "Rainbow", hues: [0, 45, 90, 160, 220, 280]),
    ]
}

/// Turns the music analysis (beat grid + sections) or screen colors into rate-limited
/// bulb writes on dp 28 (`0` = jump, `1` = bulb's own gradient).
///
/// Music, like a lighting desk:
/// - **Groove:** pulse on the beat grid. Beat 1 of the bar: new color at full. Other beats:
///   same color, softer. Above 145 BPM only beats 1 and 3 (half-time). Intense: every beat full.
/// - **Breakdown / quiet:** no flashes, slow gradient fades through the palette.
/// - **Build-up:** pulses get brighter, then double to half-beats.
/// - **Drop:** white flash, then one bar of white/color strobing on half-beats.
final class LightEngine {
    private let q = DispatchQueue(label: "tuyaglow.engine", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private weak var client: TuyaClient?

    // Settings (set from UI; read on q)
    private var mode: Mode = .off
    private var intense = false
    private var palette = Palette.all[0]
    private var ceiling: Float = 1

    // Music state
    private var section: Section = .silent
    private var locked = false
    private var period = 0.5
    private var buildStart = 0.0
    private var dropUntil = 0.0
    private var halfBeatAt: Double?
    private var ambientNextAt = 0.0
    private var whiteNext = false
    private var buildLevel: Float = 0.4

    // Current light
    private var idx = 0
    private var hue = 0
    private var sat = 1000
    private var level: Float = 0
    private var gradient = false
    private var pulseAt = 0.0
    private var dirty = false

    // Screen state
    private var target: (h: Float, s: Float, v: Float)?
    private var smooth: (r: Float, g: Float, b: Float, v: Float) = (0, 0, 0, 0)
    private var haveSmooth = false

    // Output
    private var lastSendAt = 0.0
    private var lastSent: (h: Int, s: Int, v: Int, g: Bool) = (-1, -1, -1, false)
    private let start = Date()

    private var now: Double { Date().timeIntervalSince(start) }
    private var minGap: Double { mode == .music && intense ? 0.05 : 0.1 }

    func attach(_ c: TuyaClient?) { q.async { self.client = c } }

    func configure(mode: Mode, intense: Bool, palette: Palette, ceiling: Float) {
        q.async {
            let changed = mode != self.mode
            self.mode = mode
            self.intense = intense
            self.palette = palette
            self.ceiling = max(0.05, min(1, ceiling))
            if changed { self.reset() }
            self.dirty = true
            if mode == .off || mode == .light { self.stopTimer() } else { self.startTimer() }
        }
    }

    private func reset() {
        level = 0; haveSmooth = false; target = nil
        lastSent = (-1, -1, -1, false)
        idx = 0; hue = palette.hues[0]; sat = 1000
        section = .silent; locked = false; dropUntil = 0; halfBeatAt = nil; ambientNextAt = 0
    }

    // MARK: inputs

    func handle(_ e: BeatDetector.Event) {
        q.async {
            guard self.mode == .music else { return }
            let t = self.now
            let dropping = t < self.dropUntil
            switch e {
            case .tempo(_, let l):
                self.locked = l
            case .section(let s):
                self.section = s
                if s == .build { self.buildStart = t }
                if s == .breakdown || s == .silent { self.ambientNextAt = t }
            case .drop:
                self.dropUntil = t + 4 * self.period
                self.whiteNext = false
                self.flash(advance: true, v: 1, white: true)
                self.halfBeatAt = t + self.period / 2
            case .kick:
                // Fallback until the beat grid locks.
                guard !self.locked, self.section == .groove, !dropping else { return }
                self.flash(advance: true, v: 1)
            case .beat(_, let barPos, let p):
                self.period = p
                if dropping {
                    self.flash(advance: true, v: 1, white: self.whiteNext)
                    self.whiteNext.toggle()
                    self.halfBeatAt = t + p / 2
                    return
                }
                switch self.section {
                case .groove:
                    if 60 / p > 145, barPos % 2 == 1 { return }   // half-time for fast tracks
                    if self.intense { self.flash(advance: true, v: 1) }
                    else { self.flash(advance: barPos == 0, v: barPos == 0 ? 1 : 0.6) }
                case .build:
                    let prog = Float(min(1, (t - self.buildStart) / 8))
                    self.buildLevel = 0.35 + 0.65 * prog
                    self.flash(advance: true, v: self.buildLevel)
                    if prog > 0.5 { self.halfBeatAt = t + p / 2 }
                case .breakdown, .silent:
                    break
                }
            case .hat(let s):
                guard self.intense, self.section == .groove, !dropping, t - self.pulseAt > 0.06 else { return }
                self.flash(advance: true, v: 0.55 + 0.35 * s)
            }
        }
    }

    /// Jump to a color at `v`. The glow step in `tick` dims it again shortly after.
    private func flash(advance: Bool, v: Float, white: Bool = false) {
        if advance {
            idx = (idx + 1) % palette.hues.count
            hue = palette.hues[idx]
        }
        sat = white ? 0 : 1000
        level = v
        gradient = false
        pulseAt = now
        dirty = true
        flushIfAllowed()
    }

    private var lastLog = 0.0
    func handleScreen(r: Float, g: Float, b: Float, lum: Float) {
        q.async {
            guard self.mode == .screen else { return }
            let a: Float = self.haveSmooth ? 0.35 : 1
            let v = min(1, 0.15 + lum * 1.6)
            self.smooth = (self.smooth.r + (r - self.smooth.r) * a, self.smooth.g + (g - self.smooth.g) * a,
                           self.smooth.b + (b - self.smooth.b) * a, self.smooth.v + (v - self.smooth.v) * a)
            self.haveSmooth = true
            let (h, s, _) = rgbToHsv(self.smooth.r, self.smooth.g, self.smooth.b)
            self.target = (h, s, self.smooth.v)
            self.dirty = true
        }
    }

    // MARK: output

    private func startTimer() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now(), repeating: .milliseconds(10), leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func stopTimer() { timer?.cancel(); timer = nil }

    private func tick() {
        if mode == .music { musicTick() }
        flushIfAllowed()
    }

    private func musicTick() {
        let t = now
        let dropping = t < dropUntil
        // Scheduled half-beat hit (drop strobe, late build-up).
        if let hb = halfBeatAt, t >= hb {
            halfBeatAt = nil
            if dropping {
                flash(advance: true, v: 1, white: whiteNext)
                whiteNext.toggle()
            } else if section == .build {
                flash(advance: true, v: buildLevel)
            }
        }
        if !dropping, section == .breakdown || section == .silent {
            // Ambient: slow fades handled by the bulb's own gradient.
            if t >= ambientNextAt {
                ambientNextAt = t + 2.5
                idx = (idx + 1) % palette.hues.count
                hue = palette.hues[idx]
                sat = 1000
                level = section == .silent ? 0.1 : 0.3
                gradient = true
                dirty = true
            }
            return
        }
        // Pulse: after a short hit, drop to a dim glow in the same color.
        let hold = intense ? 0.07 : 0.1
        let glow: Float = section == .build ? 0.08 + 0.25 * (buildLevel - 0.35) / 0.65 : 0.15
        if level > glow, t - pulseAt > hold {
            level = glow
            sat = 1000
            dirty = true
        }
    }

    private func flushIfAllowed() {
        guard dirty, let client, now - lastSendAt >= minGap else { return }
        var h = 0, s = 0, v = 0, g = false
        switch mode {
        case .off, .light: return
        case .music:
            h = hue; s = sat; v = Int(level * ceiling * 1000); g = gradient
        case .screen:
            guard let tg = target else { return }
            h = Int(tg.h * 360) % 360; s = Int(tg.s * 1000); v = Int(tg.v * ceiling * 1000)
        }
        v = max(10, min(1000, v))
        // Skip tiny changes so they don't eat the rate budget.
        let dv = abs(v - lastSent.v), dh = min(abs(h - lastSent.h), 360 - abs(h - lastSent.h)), ds = abs(s - lastSent.s)
        let minDv = mode == .music ? 40 : 25
        if lastSent.v >= 0, dh < 4, ds < 30, dv < minDv, g == lastSent.g { dirty = false; return }
        lastSent = (h, s, v, g)
        lastSendAt = now
        dirty = false
        let hex = String(format: "%@%04x%04x%04x00000000", g ? "1" : "0", h, s, v)
        client.send(dps: ["28": hex])
    }
}

func rgbToHsv(_ r: Float, _ g: Float, _ b: Float) -> (Float, Float, Float) {
    let mx = max(r, g, b), mn = min(r, g, b), d = mx - mn
    var h: Float = 0
    if d > 0 {
        if mx == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) }
        else if mx == g { h = (b - r) / d + 2 }
        else { h = (r - g) / d + 4 }
        h /= 6
        if h < 0 { h += 1 }
    }
    return (h, mx > 0 ? d / mx : 0, mx)
}
