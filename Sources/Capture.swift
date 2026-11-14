import AppKit
import AVFoundation
import CoreImage
import CoreMedia
import Foundation
import ScreenCaptureKit

/// System audio + low-res main-display frames via ScreenCaptureKit.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private let audioQ = DispatchQueue(label: "tuyaglow.audio", qos: .userInteractive)
    private let videoQ = DispatchQueue(label: "tuyaglow.video", qos: .userInitiated)
    private var mono: [Float] = []
    private var vStats: [String: Int] = [:]
    private var vStatsAt = Date()

    var onAudio: ((UnsafeBufferPointer<Float>, Double) -> Void)?
    var onColor: ((Float, Float, Float, Float) -> Void)?   // dominant r g b, mean luminance, all 0...1
    var onError: ((String) -> Void)?

    private(set) var displayID: CGDirectDisplayID?

    /// Display holding the frontmost app's frontmost normal window, if any.
    static func activeDisplayID() -> CGDirectDisplayID? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              pid != ProcessInfo.processInfo.processIdentifier,
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for w in list where (w[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && (w[kCGWindowLayer as String] as? Int) == 0 {
            guard let bd = w[kCGWindowBounds as String] as? NSDictionary,
                  let r = CGRect(dictionaryRepresentation: bd), r.width > 50, r.height > 50 else { continue }
            var id: CGDirectDisplayID = 0
            var n: UInt32 = 0
            if CGGetDisplaysWithPoint(CGPoint(x: r.midX, y: r.midY), 1, &id, &n) == .success, n > 0 { return id }
        }
        return nil
    }

    /// `display`: a specific display, or nil to use the active one (falls back to main).
    func start(videoFPS: Int, display wanted: CGDirectDisplayID? = nil) async throws {
        await stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let mainID = wanted ?? Capture.activeDisplayID() ?? CGMainDisplayID()
        guard let display = content.displays.first(where: { $0.displayID == mainID }) ?? content.displays.first else {
            throw NSError(domain: "TuyaGlow", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display found"])
        }
        blog("displays: " + content.displays.map { "\($0.displayID) \($0.width)x\($0.height)" }.joined(separator: ", ") + " main=\(mainID) picked=\(display.displayID) preflight=\(CGPreflightScreenCaptureAccess())")
        let cfg = SCStreamConfiguration()
        cfg.capturesAudio = true
        cfg.excludesCurrentProcessAudio = true
        cfg.sampleRate = 48_000
        cfg.channelCount = 2
        cfg.width = 64
        cfg.height = 36
        cfg.pixelFormat = kCVPixelFormatType_32BGRA
        cfg.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, videoFPS)))
        cfg.queueDepth = 3
        cfg.showsCursor = false
        let s = SCStream(filter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg, delegate: self)
        try s.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQ)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQ)
        try await s.startCapture()
        stream = s
        displayID = display.displayID
    }

    func stop() async {
        guard let s = stream else { return }
        stream = nil
        displayID = nil
        try? await s.stopCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error.localizedDescription)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sb: CMSampleBuffer, of type: SCStreamOutputType) {
        guard sb.isValid else { return }
        switch type {
        case .audio: handleAudio(sb)
        case .screen: handleVideo(sb)
        default: break
        }
    }

    private func handleAudio(_ sb: CMSampleBuffer) {
        guard let desc = sb.formatDescription?.audioStreamBasicDescription,
              desc.mFormatFlags & kAudioFormatFlagIsFloat != 0 else { return }
        let frames = sb.numSamples
        guard frames > 0 else { return }
        try? sb.withAudioBufferList { list, _ in
            if mono.count != frames { mono = [Float](repeating: 0, count: frames) }
            let chans = list.count
            let interleaved = chans == 1 && desc.mChannelsPerFrame > 1
            mono.withUnsafeMutableBufferPointer { out in
                for i in 0..<frames { out[i] = 0 }
                if interleaved, let p = list[0].mData?.assumingMemoryBound(to: Float.self) {
                    let ch = Int(desc.mChannelsPerFrame)
                    for i in 0..<frames {
                        var s: Float = 0
                        for c in 0..<ch { s += p[i * ch + c] }
                        out[i] = s / Float(ch)
                    }
                } else {
                    for buf in list {
                        guard let p = buf.mData?.assumingMemoryBound(to: Float.self) else { continue }
                        for i in 0..<frames { out[i] += p[i] / Float(chans) }
                    }
                }
                onAudio?(UnsafeBufferPointer(out), desc.mSampleRate)
            }
        }
    }

    private func handleVideo(_ sb: CMSampleBuffer) {
        let attach = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        let raw = attach?.first?[.status] as? Int
        guard let onColor, let raw, SCFrameStatus(rawValue: raw) == .complete,
              let px = sb.imageBuffer else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(px)?.assumingMemoryBound(to: UInt8.self) else { return }
        let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px), row = CVPixelBufferGetBytesPerRow(px)
        // Weight vivid, bright pixels more so the "dominant" color wins over grey UI.
        var r: Float = 0, g: Float = 0, b: Float = 0, wsum: Float = 0
        var ar: Float = 0, ag: Float = 0, ab: Float = 0
        for y in 0..<h {
            let line = base + y * row
            for x in 0..<w {
                let p = line + x * 4
                let bb = Float(p[0]) / 255, gg = Float(p[1]) / 255, rr = Float(p[2]) / 255
                ar += rr; ag += gg; ab += bb
                let mx = max(rr, gg, bb), mn = min(rr, gg, bb)
                let sat = mx > 0 ? (mx - mn) / mx : 0
                let wt = mx * (0.15 + sat * sat * 4)
                r += rr * wt; g += gg * wt; b += bb * wt; wsum += wt
            }
        }
        let count = Float(w * h)
        let lum = (0.2126 * ar + 0.7152 * ag + 0.0722 * ab) / count
        if wsum > 0.001 * count {
            onColor(r / wsum, g / wsum, b / wsum, lum)
        } else {
            onColor(ar / count, ag / count, ab / count, lum)
        }
    }
}
