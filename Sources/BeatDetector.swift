import Accelerate
import Foundation

enum Section: String { case silent = "Quiet", groove = "Groove", breakdown = "Breakdown", build = "Build-up" }

/// Music analysis over mono audio. FFT 2048, hop 512 (~10.7 ms at 48 kHz).
///
/// Works like an automatic lighting desk:
/// - **Beat grid:** tempo from autocorrelation of an onset envelope, phase from a comb
///   over recent beats, then *predicted* beats fire on the grid (a quiet kick is not a miss).
/// - **Bar position:** the beat slot with the strongest bass over recent bars is beat 1.
/// - **Sections:** bass energy against its recent peak gives groove / breakdown;
///   rising highs in a breakdown give build-up; bass slamming back gives a drop.
final class BeatDetector {
    enum Event {
        case beat(index: Int, barPos: Int, period: Double)   // predicted, on the locked grid
        case kick(strength: Float)                            // raw strong kick (used before lock)
        case hat(strength: Float)
        case section(Section)
        case drop
        case tempo(bpm: Double, locked: Bool)
    }

    let sampleRate: Double
    private let n = 2048, hop = 512
    let hopDur: Double
    private let log2n: vDSP_Length = 11
    private let setup: FFTSetup
    private let window: [Float]
    private var ring: [Float]
    private var filled = 0
    private var sinceHop = 0
    private var real: [Float], imag: [Float], mags: [Float]
    private let bassBins: Range<Int>, highBins: Range<Int>, broadBins: Range<Int>, energyHighBins: Range<Int>

    /// Fire beats this many seconds early to cover capture + network + bulb latency.
    var lead = 0.07
    var linearScale: Float = 0.002

    var onEvent: ((Event) -> Void)?
    var onFlux: ((Float, Float) -> Void)?   // bass, high (tests)

    // Clock: audio time of the newest analysed hop. Hop k (1-based) is at k * hopDur.
    private(set) var clock = 0.0
    private var hopCount = 0

    // Onset features
    private var prevBass: [Float] = [], prevHigh: [Float] = [], prevBroad: [Float] = []
    private var bassHist = RollingStats(size: 60), highHist = RollingStats(size: 60)
    private var level = RollingStats(size: 200)
    private var bassPeak: Float = 0, broadPeak: Float = 0
    private var lastKick = -1.0, lastHat = -1.0

    // Onset envelope rings (one value per hop)
    private let envLen = 560   // ~6 s
    private var env: [Float], bassEnv: [Float]

    // Grid tracker
    private var period = 0.0
    private var nextBeat = 0.0
    private var beatIndex = 0
    private var locked = false
    private var lowConf = 0
    private var pendingPeriod = 0.0, votes = 0
    private var barAcc = [Float](repeating: 0, count: 4)
    private var downPhase = 0
    private var pastBeats: [(t: Double, idx: Int)] = []
    private var lastTempoEmit = -10.0

    // Sections
    private(set) var section: Section = .silent
    private var bassS: Float = 0, highS: Float = 0, allS: Float = 0, bassRef: Float = 0
    private var trend: [(high: Float, all: Float)] = []   // sampled every 24 hops (~0.26 s)
    private var sectionSince = 0.0
    private var lowBassFor = 0.0, quietFor = 0.0, risingFor = 0.0, fallingFor = 0.0

    init(sampleRate: Double = 48_000) {
        self.sampleRate = sampleRate
        hopDur = Double(hop) / sampleRate
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
        ring = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imag = [Float](repeating: 0, count: n / 2)
        mags = [Float](repeating: 0, count: n / 2)
        env = [Float](repeating: 0, count: envLen)
        bassEnv = [Float](repeating: 0, count: envLen)
        let binHz = sampleRate / Double(n)
        bassBins = max(1, Int(40 / binHz))..<Int(160 / binHz) + 1
        highBins = Int(5_000 / binHz)..<min(n / 2, Int(12_000 / binHz))
        broadBins = 2..<min(n / 2, Int(8_000 / binHz))
        energyHighBins = Int(2_000 / binHz)..<min(n / 2, Int(12_000 / binHz))
    }

    deinit { vDSP_destroy_fftsetup(setup) }

    func process(_ samples: UnsafeBufferPointer<Float>) {
        for s in samples {
            ring[filled % n] = s
            filled += 1
            sinceHop += 1
            if sinceHop >= hop, filled >= n {
                sinceHop = 0
                analyze()
            }
        }
    }

    // MARK: - per hop

    private func analyze() {
        hopCount += 1
        clock = Double(hopCount) * hopDur

        let start = filled % n
        var frame = [Float](repeating: 0, count: n)
        frame.withUnsafeMutableBufferPointer { f in
            ring.withUnsafeBufferPointer { r in
                let tail = n - start
                f.baseAddress!.update(from: r.baseAddress! + start, count: tail)
                (f.baseAddress! + tail).update(from: r.baseAddress!, count: start)
            }
        }
        let rms = vDSP.rootMeanSquare(frame)
        vDSP.multiply(frame, window, result: &frame)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                frame.withUnsafeBytes { fb in
                    vDSP_ctoz(fb.bindMemory(to: DSPComplex.self).baseAddress!, 2, &split, 1, vDSP_Length(n / 2))
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                mags.withUnsafeMutableBufferPointer { mp in
                    vDSP_zvabs(&split, 1, mp.baseAddress!, 1, vDSP_Length(n / 2))
                }
            }
        }

        updateSections(rms: rms)

        if rms < 0.002 {
            prevBass = []; prevHigh = []; prevBroad = []
            pushEnv(0, 0)
            if locked, quietFor > 1.0 { setLocked(false) }
            return
        }
        level.push(rms)
        let gain = 1 / max(level.mean, 0.003)

        // Bass: linear magnitudes so soft hits score lower than full kicks.
        let scale = linearScale
        let bassFlux = flux(bins: bassBins, prev: &prevBass) { $0 * gain * scale }
        let highFlux = flux(bins: highBins, prev: &prevHigh) { log1p($0 * gain * 0.05) }
        let broadFlux = flux(bins: broadBins, prev: &prevBroad) { log1p($0 * gain * 0.05) }
        onFlux?(bassFlux, highFlux)

        // Raw strong-kick onsets (fallback before the grid locks).
        bassPeak = max(bassFlux, bassPeak * 0.996)
        let bassThr = bassHist.mean + 2.0 * bassHist.std
        bassHist.push(bassFlux)
        if bassHist.count > 10, bassFlux > bassThr, bassFlux > 0.5, bassFlux >= 0.6 * bassPeak, clock - lastKick >= 0.25 {
            lastKick = clock
            onEvent?(.kick(strength: min(1, bassFlux / max(bassPeak, 0.01))))
        }
        let highThr = highHist.mean + 1.8 * highHist.std
        highHist.push(highFlux)
        if highHist.count > 10, highFlux > highThr, highFlux > 0.4 * max(highHist.mean, 0.05), clock - lastHat >= 0.06 {
            lastHat = clock
            onEvent?(.hat(strength: min(1, (highFlux - highThr) / max(highThr, 0.01))))
        }

        // Onset envelope for the tracker: kick-weighted plus broadband for kick-light music.
        broadPeak = max(broadFlux, broadPeak * 0.996)
        let oe = bassFlux / max(bassPeak, 1e-6) + 0.5 * broadFlux / max(broadPeak, 1e-6)
        pushEnv(oe, bassFlux / max(bassPeak, 1e-6))

        if hopCount % 24 == 0, hopCount >= 280 { estimateGrid() }
        fireBeats()
        scoreDownbeats()
    }

    private func flux(bins: Range<Int>, prev: inout [Float], _ f: (Float) -> Float) -> Float {
        var cur = [Float](repeating: 0, count: bins.count)
        for (i, b) in bins.enumerated() { cur[i] = f(mags[b]) }
        defer { prev = cur }
        guard prev.count == cur.count else { return 0 }
        var sum: Float = 0
        for i in 0..<cur.count { sum += max(0, cur[i] - prev[i]) }
        return sum / Float(cur.count)
    }

    private func pushEnv(_ v: Float, _ b: Float) {
        env[(hopCount - 1) % envLen] = v
        bassEnv[(hopCount - 1) % envLen] = b
    }

    /// Envelope value at hop k (1-based), 0 if out of the ring.
    private func envAt(_ k: Int, _ arr: [Float]) -> Float {
        guard k >= 1, k <= hopCount, k > hopCount - envLen else { return 0 }
        return arr[(k - 1) % envLen]
    }

    // MARK: - beat grid

    private func estimateGrid() {
        let m = min(hopCount, envLen)
        var x = [Float](repeating: 0, count: m)
        for i in 0..<m { x[i] = envAt(hopCount - m + 1 + i, env) }
        // Widen the sharp onset peaks so a beat period that falls between two whole hop
        // counts still correlates fully (otherwise 150 BPM loses to 100 BPM).
        let kernel: [Float] = [1, 2, 3, 2, 1].map { $0 / 9 }
        var sm = [Float](repeating: 0, count: m)
        for i in 0..<m {
            var v: Float = 0
            for (j, w) in kernel.enumerated() { let k = i + j - 2; if k >= 0 && k < m { v += w * x[k] } }
            sm[i] = v
        }
        x = sm
        let mean = x.reduce(0, +) / Float(m)
        for i in 0..<m { x[i] -= mean }

        let minLag = Int((60.0 / 200.0) / hopDur), maxLag = Int((60.0 / 65.0) / hopDur) + 1
        func ac(_ l: Int) -> Float {
            guard l < m - 1 else { return 0 }
            var s: Float = 0
            for i in l..<m { s += x[i] * x[i - l] }
            return s / Float(m - l)
        }
        var acs = [Float](repeating: 0, count: maxLag + 2)
        for l in minLag...min(maxLag, m - 2) { acs[l] = ac(l) }
        var score = [Float](repeating: -.infinity, count: maxLag + 2)
        for l in minLag...maxLag {
            let bpm = 60.0 / (Double(l) * hopDur)
            let prior = Float(exp(-0.5 * pow(log2(bpm / 120.0) / 0.8, 2)))
            score[l] = acs[l] * prior
        }
        var best = minLag
        for l in minLag...maxLag where score[l] > score[best] { best = l }
        guard score[best] > 0 else { return }
        // Parabolic refinement.
        var lf = Double(best)
        if best > minLag, best < maxLag {
            let a = Double(score[best - 1]), b = Double(score[best]), c = Double(score[best + 1])
            let d = a - 2 * b + c
            if d < 0 { lf += 0.5 * (a - c) / d }
        }
        let est = lf * hopDur

        // Tempo: smooth small changes, switch on 3 agreeing estimates.
        if period == 0 {
            period = est
        } else if abs(est / period - 1) < 0.06 {
            period = period * 0.85 + est * 0.15
            votes = 0
        } else {
            if pendingPeriod > 0, abs(est / pendingPeriod - 1) < 0.06 { votes += 1 } else { pendingPeriod = est; votes = 1 }
            if votes >= 3 { period = est; votes = 0; setLocked(false) }
        }

        // Phase: comb over the last 8 beats.
        let p = period / hopDur
        let phases = Int(p.rounded(.up))
        var bestPhase = 0
        var bestScore: Float = -1, sum: Float = 0
        for ph in 0..<phases {
            var s: Float = 0, w: Float = 1
            for k in 0..<8 {
                let idx = hopCount - ph - Int((Double(k) * p).rounded())
                s += w * (envAt(idx, env) + 0.5 * envAt(idx - 1, env) + 0.5 * envAt(idx + 1, env))
                w *= 0.85
            }
            sum += s
            if s > bestScore { bestScore = s; bestPhase = ph }
        }
        let conf = bestScore / max(sum / Float(phases), 1e-6)

        var nb = Double(hopCount - bestPhase) * hopDur
        while nb <= clock + lead { nb += period }

        if !locked {
            if conf > 1.7 {
                nextBeat = nb
                setLocked(true)
            }
        } else {
            if conf < 1.25 { lowConf += 1; if lowConf >= 5 { setLocked(false) } } else { lowConf = 0 }
            var err = nb - nextBeat
            while err > period / 2 { err -= period }
            while err < -period / 2 { err += period }
            nextBeat += 0.3 * err
        }
        if clock - lastTempoEmit > 2 {
            lastTempoEmit = clock
            onEvent?(.tempo(bpm: 60 / period, locked: locked))
        }
    }

    private func setLocked(_ v: Bool) {
        guard v != locked else { return }
        locked = v
        lowConf = 0
        lastTempoEmit = clock
        onEvent?(.tempo(bpm: period > 0 ? 60 / period : 0, locked: v))
    }

    private func fireBeats() {
        guard locked, period > 0 else { return }
        // Skip beats we are already far past (e.g. after a stall).
        while nextBeat < clock + lead - period * 0.5 { nextBeat += period; beatIndex += 1 }
        while clock + lead >= nextBeat {
            let pos = ((beatIndex - downPhase) % 4 + 4) % 4
            onEvent?(.beat(index: beatIndex, barPos: pos, period: period))
            pastBeats.append((nextBeat, beatIndex))
            beatIndex += 1
            nextBeat += period
        }
    }

    /// Once the audio for a fired beat has been analysed, credit its bass to its bar slot.
    private func scoreDownbeats() {
        while let b = pastBeats.first, clock > b.t + 0.05 {
            pastBeats.removeFirst()
            let k0 = Int(((b.t - 0.035) / hopDur).rounded(.down)), k1 = Int(((b.t + 0.035) / hopDur).rounded(.up))
            var v: Float = 0
            if k0 <= k1 { for k in k0...k1 { v = max(v, envAt(k, bassEnv)) } }
            let slot = b.idx % 4
            if slot == 0 { for i in 0..<4 { barAcc[i] *= 0.9 } }   // decay once per bar so recency doesn't win
            barAcc[slot] += v
            let best = barAcc.indices.max { barAcc[$0] < barAcc[$1] }!
            let mean = barAcc.reduce(0, +) / 4
            if barAcc[best] > 1.15 * mean { downPhase = best }
        }
    }

    // MARK: - sections

    private func updateSections(rms: Float) {
        var bassE: Float = 0, highE: Float = 0
        for b in bassBins { bassE += mags[b] }
        for b in energyHighBins { highE += mags[b] }
        highE /= Float(energyHighBins.count)
        bassE /= Float(bassBins.count)
        let a = Float(hopDur / 0.5)
        bassS += (bassE - bassS) * a
        highS += (highE - highS) * a
        allS += (rms - allS) * a
        bassRef = max(bassS, bassRef * Float(pow(0.5, hopDur / 20)))

        if hopCount % 24 == 0 {
            trend.append((highS, allS))
            if trend.count > 8 { trend.removeFirst() }   // ~2 s back
        }
        let dt = hopDur
        quietFor = rms < 0.002 ? quietFor + dt : 0
        let bassPresent = bassS > 0.35 * bassRef
        // Instant: a single bass hit at the old groove level. Average: bass has settled back.
        let bassBack = bassE > 1.0 * bassRef || bassS > 0.6 * bassRef
        lowBassFor = bassPresent ? 0 : lowBassFor + dt
        if let old = trend.first, trend.count >= 8 {
            let rising = highS > 1.25 * old.high && allS > 1.05 * old.all
            let falling = highS < 0.8 * old.high
            risingFor = rising ? risingFor + dt : 0
            fallingFor = falling ? fallingFor + dt : 0
        }

        var next = section
        switch section {
        case .silent:
            if quietFor == 0 && allS > 0.003 { next = bassPresent ? .groove : .breakdown }
        case .groove:
            if quietFor > 0.6 { next = .silent }
            else if lowBassFor > 1.0 { next = .breakdown }
        case .breakdown, .build:
            if quietFor > 0.6 { next = .silent }
            else if bassBack {
                if clock - sectionSince > 1.5 { onEvent?(.drop) }
                next = .groove
            } else if section == .breakdown, risingFor > 1.0 { next = .build }
            else if section == .build, fallingFor > 1.5 { next = .breakdown }
        }
        if next != section {
            section = next
            sectionSince = clock
            risingFor = 0; fallingFor = 0; lowBassFor = 0
            onEvent?(.section(next))
        }
    }
}

struct RollingStats {
    private var buf: [Float]
    private var i = 0
    private(set) var count = 0
    init(size: Int) { buf = [Float](repeating: 0, count: size) }
    mutating func push(_ v: Float) { buf[i] = v; i = (i + 1) % buf.count; count = min(count + 1, buf.count) }
    var mean: Float { count == 0 ? 0 : buf.prefix(count).reduce(0, +) / Float(count) }
    var std: Float {
        guard count > 1 else { return 0 }
        let m = mean
        return sqrt(buf.prefix(count).reduce(0) { $0 + ($1 - m) * ($1 - m) } / Float(count))
    }
}
