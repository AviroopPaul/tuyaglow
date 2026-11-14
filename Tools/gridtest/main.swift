import Foundation

// Synthetic songs for the beat-grid tracker and section detector.
let sr = 48_000.0
var seed: UInt64 = 7
func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double(seed >> 11) / Double(1 << 53) * 2 - 1 }
func kick(_ t: Double) -> Double { t < 0 || t > 0.15 ? 0 : exp(-t * 30) * sin(2 * .pi * (55 + 60 * exp(-t * 40)) * t) }

struct Part { var secs: Double; var kicks: Bool; var bass: Bool; var riser: Bool }

/// Returns samples and true kick times.
func song(bpm: Double, parts: [Part], buried: Bool = true, bassAmp: Double = 0.2) -> ([Float], [Double]) {
    let beat = 60 / bpm
    let total = parts.reduce(0) { $0 + $1.secs }
    let n = Int(total * sr)
    var x = [Float](repeating: 0, count: n)
    var kicks: [Double] = []
    var prevN = 0.0
    var t0 = 0.0
    var lastBi = -1
    for p in parts {
        let i0 = Int(t0 * sr), i1 = min(n, Int((t0 + p.secs) * sr))
        for i in i0..<i1 {
            let t = Double(i) / sr
            let local = t - t0
            var s = 0.06 * sin(2 * .pi * 220 * t) + 0.04 * sin(2 * .pi * 277 * t)   // pad
            let bi = Int(t / beat)
            let bt = t - Double(bi) * beat
            if p.kicks {
                                // ~30% of kicks buried at 25%, at random
                var h = UInt64(bi) &* 0x9E3779B97F4A7C15; h ^= h >> 29
                var amp = buried && h % 10 < 3 ? 0.25 : 1.0
                if bi % 4 == 0 { amp = 1.3 }   // bar downbeat slightly harder
                s += amp * kick(bt)
                if bi != lastBi { kicks.append(Double(bi) * beat); lastBi = bi }
            }
            if p.bass {
                let ot = t - (Double(bi) + 0.5) * beat
                if ot >= 0 && ot < 0.2 { s += bassAmp * exp(-ot * 12) * sin(2 * .pi * [70.0, 82, 98, 73][bi % 4] * ot) }
            }
            // hats on 8ths, high-passed noise
            let ht = t.truncatingRemainder(dividingBy: beat / 2)
            if ht < 0.03 { let r = rnd(); s += 0.12 * (r - prevN) * exp(-ht * 150); prevN = r }
            if p.riser {
                let k = local / p.secs   // 0...1
                let r = rnd(); s += 0.5 * k * k * (r - prevN); prevN = r
                // accelerating snare roll in the last half
                let div = k < 0.5 ? beat : (k < 0.8 ? beat / 2 : beat / 4)
                let st = t.truncatingRemainder(dividingBy: div)
                if st < 0.05 { s += 0.3 * k * rnd() * exp(-st * 60) }
            }
            x[i] = Float(s * 0.6)
        }
        t0 += p.secs
    }
    return (x, kicks)
}

var comb = true
func analyse(_ name: String, _ x: [Float], kicks: [Double], bpm: Double) {
    let d = BeatDetector(sampleRate: sr)
    var beats: [(t: Double, pos: Int)] = []
    var log: [String] = []
    var lockAt: Double?
    d.onEvent = { e in
        switch e {
        case .beat(_, let pos, _): beats.append((d.clock + d.lead, pos))
        case .tempo(let b, let l):
            if l, lockAt == nil { lockAt = d.clock }
            log.append(String(format: "%.1fs tempo %.1f %@", d.clock, b, l ? "locked" : "unlocked"))
        case .section(let s): log.append(String(format: "%.1fs section %@", d.clock, s.rawValue))
        case .drop: log.append(String(format: "%.1fs DROP", d.clock))
        default: break
        }
    }
    var i = 0
    while i < x.count {
        let c = min(480, x.count - i)
        x.withUnsafeBufferPointer { d.process(UnsafeBufferPointer(rebasing: $0[i..<i + c])) }
        i += c
    }
    // Score: beats fired vs kicks after lock; timing error of each beat to nearest kick.
    let start = (lockAt ?? 0) + 1
    let k = kicks.filter { $0 > start }
    let b = beats.filter { $0.t > start }
    var errs: [Double] = []
    var hit = 0
    for kt in k {
        if let near = b.min(by: { abs($0.t - kt) < abs($1.t - kt) }), abs(near.t - kt) < 0.06 { hit += 1; errs.append((near.t - kt) * 1000) }
    }
    errs.sort()
    let med = errs.isEmpty ? 0 : errs[errs.count / 2]
    let spread = errs.isEmpty ? 0 : errs[errs.count * 9 / 10] - errs[errs.count / 10]
    let downs = b.filter { $0.pos == 0 }.count
    let onBar = b.filter { $0.pos == 0 }.filter { bt in let q = (bt.t / (60 / bpm)).rounded(); return Int(q) % 4 == 0 && abs(bt.t - q * 60 / bpm) < 0.06 }.count
    print(String(format: "%@: lock %.1fs, kicks after lock %d, beats %d, matched %d, timing median %+.0f ms (10-90%% spread %.0f ms), downbeats %d (%d on true bar starts)",
                 name, lockAt ?? -1, k.count, b.count, hit, med, spread, downs, onBar))
    for l in log where !l.contains("tempo") || l.contains("locked") { print("   ", l) }
}

for c in [false] {
comb = c
print("==== comb", c)
for bpm in [90.0, 128, 150, 174] {
    let (x, k) = song(bpm: bpm, parts: [Part(secs: 20, kicks: true, bass: true, riser: false)])
    analyse("\(Int(bpm)) BPM", x, kicks: k, bpm: bpm)
}
let (px, pk) = song(bpm: 145, parts: [Part(secs: 20, kicks: true, bass: true, riser: false)], bassAmp: 0.5)
analyse("145 BPM strong off-beat bass", px, kicks: pk, bpm: 145)
let (x, k) = song(bpm: 128, parts: [
    Part(secs: 10, kicks: true, bass: true, riser: false),
    Part(secs: 5, kicks: false, bass: false, riser: false),
    Part(secs: 6, kicks: false, bass: false, riser: true),
    Part(secs: 10, kicks: true, bass: true, riser: false),
])
analyse("128 BPM structure", x, kicks: k, bpm: 128)
}
