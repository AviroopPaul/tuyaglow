import CommonCrypto
import CryptoKit
import Foundation
import Network

// Tuya local LAN protocol, versions 3.3, 3.4 and 3.5.
// Ported from tinytuya (MIT): core/{message_helper,XenonDevice,crypto_helper,udp_helper}.py.
//
// 3.3: 0x55AA frames, CRC32, AES-128-ECB with the local key. No handshake.
// 3.4: 0x55AA frames, HMAC-SHA256, AES-ECB, session key negotiated at connect.
// 3.5: 0x6699 frames, AES-GCM, session key negotiated at connect.

enum TuyaCmd: UInt32 {
    case sessStart = 3, sessResp = 4, sessFinish = 5, control = 7, status = 8
    case heartbeat = 9, dpQuery = 10, controlNew = 13, dpQueryNew = 16
}

struct TuyaFrame {
    var seq: UInt32
    var cmd: UInt32
    var payload: Data
}

extension Data {
    mutating func appendBE<T: FixedWidthInteger>(_ v: T) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    func readBE32(_ at: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(self[startIndex + at + i]) }
        return v
    }
}

// MARK: - crypto helpers

enum TuyaCrypto {
    /// AES-128-ECB. `pad` adds/removes PKCS#7 padding.
    static func ecb(_ data: Data, key: Data, encrypt: Bool, pad: Bool = true) -> Data? {
        var out = Data(count: data.count + kCCBlockSizeAES128)
        var moved = 0
        let opts = CCOptions(kCCOptionECBMode | (pad ? kCCOptionPKCS7Padding : 0))
        let outCap = out.count
        let st = out.withUnsafeMutableBytes { o in
            data.withUnsafeBytes { i in
                key.withUnsafeBytes { k in
                    CCCrypt(CCOperation(encrypt ? kCCEncrypt : kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), opts,
                            k.baseAddress, key.count, nil, i.baseAddress, data.count, o.baseAddress, outCap, &moved)
                }
            }
        }
        guard st == kCCSuccess else { return nil }
        return out.prefix(moved)
    }

    static func hmac(_ data: Data, key: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFF_FFFF
    }
}

// MARK: - framing

enum TuyaCodec {
    enum UnpackResult { case incomplete, skip(Int), frame(TuyaFrame, Int) }

    static let prefix6699: UInt32 = 0x6699, suffix6699: UInt32 = 0x9966
    static let prefix55AA: UInt32 = 0x55AA, suffix55AA: UInt32 = 0xAA55

    // 0x6699 (3.5): header(18) | nonce(12) | ciphertext | tag(16) | suffix(4)
    static func pack6699(seq: UInt32, cmd: UInt32, payload: Data, key: SymmetricKey,
                         nonce: AES.GCM.Nonce = AES.GCM.Nonce()) throws -> Data {
        var header = Data()
        header.appendBE(prefix6699)
        header.appendBE(UInt16(0))
        header.appendBE(seq)
        header.appendBE(cmd)
        header.appendBE(UInt32(payload.count + 12 + 16))
        let box = try AES.GCM.seal(payload, using: key, nonce: nonce, authenticating: header.subdata(in: 4..<18))
        var out = header
        out.append(nonce.withUnsafeBytes { Data($0) })
        out.append(box.ciphertext)
        out.append(box.tag)
        out.appendBE(suffix6699)
        return out
    }

    // 0x55AA (3.3 / 3.4): header(16) | payload | crc32(4) or hmac(32) | suffix(4)
    static func pack55AA(seq: UInt32, cmd: UInt32, payload: Data, hmacKey: Data?) -> Data {
        var out = Data()
        out.appendBE(prefix55AA)
        out.appendBE(seq)
        out.appendBE(cmd)
        out.appendBE(UInt32(payload.count + (hmacKey == nil ? 4 : 32) + 4))
        out.append(payload)
        if let k = hmacKey { out.append(TuyaCrypto.hmac(out, key: k)) } else { out.appendBE(TuyaCrypto.crc32(out)) }
        out.appendBE(suffix55AA)
        return out
    }

    /// Parse one frame from the front of `buf`. For 0x55AA frames the payload is returned raw
    /// (retcode, version header and encryption still on); for 0x6699 it is decrypted.
    static func unpack(_ buf: Data, gcmKey: SymmetricKey?, hmacKey: Data?) -> UnpackResult {
        let b = Data(buf)
        guard b.count >= 16 else { return .incomplete }
        let p = b.readBE32(0)
        if p == prefix6699 {
            guard b.count >= 18, let key = gcmKey else { return b.count >= 18 ? .skip(4) : .incomplete }
            let length = Int(b.readBE32(14))
            let total = 18 + length + 4
            guard length >= 28, length < 64_000 else { return .skip(4) }
            guard b.count >= total else { return .incomplete }
            let nonceData = b.subdata(in: 18..<30)
            let tagStart = 18 + length - 16
            guard let nonce = try? AES.GCM.Nonce(data: nonceData),
                  let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: b.subdata(in: 30..<tagStart), tag: b.subdata(in: tagStart..<tagStart + 16)),
                  let plain = try? AES.GCM.open(box, using: key, authenticating: b.subdata(in: 4..<18))
            else { return .skip(total) }
            return .frame(TuyaFrame(seq: b.readBE32(6), cmd: b.readBE32(10), payload: plain), total)
        }
        if p == prefix55AA {
            let length = Int(b.readBE32(12))
            let total = 16 + length
            let endLen = (hmacKey == nil ? 4 : 32) + 4
            guard length >= endLen, length < 64_000 else { return .skip(4) }
            guard b.count >= total else { return .incomplete }
            let body = b.subdata(in: 0..<total - endLen)
            if let k = hmacKey {
                guard TuyaCrypto.hmac(body, key: k) == b.subdata(in: total - endLen..<total - 4) else { return .skip(total) }
            } else {
                guard TuyaCrypto.crc32(body) == b.readBE32(total - 8) else { return .skip(total) }
            }
            return .frame(TuyaFrame(seq: b.readBE32(4), cmd: b.readBE32(8), payload: b.subdata(in: 16..<total - endLen)), total)
        }
        // Resync on the next known prefix.
        for pat in [Data([0, 0, 0x66, 0x99]), Data([0, 0, 0x55, 0xAA])] {
            if let r = b.range(of: pat, in: 1..<b.count) { return .skip(r.lowerBound) }
        }
        return .skip(max(1, b.count - 3))
    }

    /// Strip a 4-byte return code and/or "3.x" + 12-byte version header, as tinytuya does.
    static func stripPrefixes(_ d: Data, version: Double) -> Data {
        var p = d
        if version < 3.5, p.count % 16 == 3 || p.count % 16 == 4 { p = p.subdata(in: 4..<p.count) }
        if p.count >= 15, p.prefix(2) == Data("3.".utf8) { p = p.subdata(in: 15..<p.count) }
        return p
    }

    /// Pull the JSON object out of a decrypted payload.
    static func json(_ payload: Data) -> [String: Any]? {
        guard let i = payload.firstIndex(of: UInt8(ascii: "{")) else { return nil }
        var tail = payload[i...]
        while let last = tail.last, last == 0 { tail = tail.dropLast() }
        return (try? JSONSerialization.jsonObject(with: tail)) as? [String: Any]
    }
}

// MARK: - client

final class TuyaClient {
    enum State: Equatable { case idle, connecting, ready, failed(String) }

    let deviceID: String
    let version: Double
    private(set) var host: String
    private let port: UInt16
    private let realKey: Data
    private let q = DispatchQueue(label: "tuyaglow.tuya")
    private var conn: NWConnection?
    private var buf = Data()
    private var seq: UInt32 = 1
    private var sessionKey: Data?
    private var localNonce = Data()
    private var heartbeat: DispatchSourceTimer?
    private var wantConnected = false
    private var retryDelay = 1.0
    private var statusWaiters: [([String: Any]?) -> Void] = []

    var onState: ((State) -> Void)?
    private(set) var state: State = .idle {
        didSet { if state != oldValue { let s = state; onState?(s) } }
    }

    init(deviceID: String, host: String, localKey: String, version: Double = 3.5, port: UInt16 = 6668) {
        self.deviceID = deviceID
        self.host = host
        self.version = version
        self.port = port
        realKey = Data(localKey.utf8)
    }

    private var key: Data { sessionKey ?? realKey }

    func start() { q.async { self.wantConnected = true; self.open() } }

    func stop() {
        q.async {
            self.wantConnected = false
            self.teardown()
            self.state = .idle
        }
    }

    func setHost(_ h: String) {
        q.async {
            guard h != self.host else { return }
            self.host = h
            if self.wantConnected { self.teardown(); self.open() }
        }
    }

    var isReady: Bool { q.sync { state == .ready } }

    /// Fire-and-forget dp write. Dropped if not connected.
    func send(dps: [String: Any]) {
        q.async {
            guard self.state == .ready else { return }
            let t = Int(Date().timeIntervalSince1970)
            if self.version >= 3.4 {
                self.write(.controlNew, json: ["protocol": 5, "t": t, "data": ["dps": dps]])
            } else {
                self.write(.control, json: ["devId": self.deviceID, "uid": self.deviceID, "t": String(t), "dps": dps])
            }
        }
    }

    /// Read current dps. Calls back on an arbitrary queue; nil on timeout.
    func queryStatus(timeout: TimeInterval = 2, _ done: @escaping ([String: Any]?) -> Void) {
        q.async {
            guard self.state == .ready else { done(nil); return }
            var fired = false
            let waiter: ([String: Any]?) -> Void = { d in if !fired { fired = true; done(d) } }
            self.statusWaiters.append(waiter)
            if self.version >= 3.4 {
                self.write(.dpQueryNew, raw: Data("{}".utf8))
            } else {
                let t = String(Int(Date().timeIntervalSince1970))
                self.write(.dpQuery, json: ["gwId": self.deviceID, "devId": self.deviceID, "uid": self.deviceID, "t": t])
            }
            self.q.asyncAfter(deadline: .now() + timeout) {
                if !fired { self.statusWaiters.removeAll(); waiter(nil) }
            }
        }
    }

    /// Blocking helper for shutdown paths. Sends and waits a moment for it to leave.
    func sendAndFlush(dps: [String: Any], wait: TimeInterval = 0.4) {
        send(dps: dps)
        let sem = DispatchSemaphore(value: 0)
        q.async { sem.signal() }
        _ = sem.wait(timeout: .now() + wait)
        Thread.sleep(forTimeInterval: 0.15)
    }

    // MARK: connection

    private func open() {
        teardown()
        state = .connecting
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 4
        let c = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: nil, tcp: tcp))
        conn = c
        c.stateUpdateHandler = { [weak self, weak c] st in
            guard let self, let c, c === self.conn else { return }
            switch st {
            case .ready:
                if self.version >= 3.4 { self.beginHandshake() } else { self.becameReady() }
            case .failed(let e): self.fail("connect: \(e)")
            case .waiting(let e): self.fail("waiting: \(e)")
            default: break
            }
        }
        c.start(queue: q)
        receive(on: c)
    }

    private func becameReady() {
        retryDelay = 1
        state = .ready
        startHeartbeat()
    }

    private func teardown() {
        heartbeat?.cancel(); heartbeat = nil
        conn?.stateUpdateHandler = nil
        conn?.cancel(); conn = nil
        buf.removeAll()
        sessionKey = nil
        let w = statusWaiters; statusWaiters.removeAll()
        w.forEach { $0(nil) }
    }

    private func fail(_ why: String) {
        teardown()
        state = .failed(why)
        guard wantConnected else { return }
        let d = retryDelay
        retryDelay = min(retryDelay * 2, 15)
        q.asyncAfter(deadline: .now() + d) { [weak self] in
            guard let self, self.wantConnected, self.conn == nil else { return }
            self.open()
        }
    }

    private func receive(on c: NWConnection) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self, weak c] data, _, done, err in
            guard let self, let c, c === self.conn else { return }
            if let data { self.buf.append(data); self.drain() }
            if done || err != nil { self.fail("closed"); return }
            self.receive(on: c)
        }
    }

    private func drain() {
        while true {
            let r = TuyaCodec.unpack(buf, gcmKey: version >= 3.5 ? SymmetricKey(data: key) : nil,
                                     hmacKey: version == 3.4 ? key : nil)
            switch r {
            case .incomplete: return
            case .skip(let n): buf.removeFirst(min(n, buf.count))
            case .frame(let f, let n):
                buf.removeFirst(n)
                handle(cmd: f.cmd, payload: decode(f.payload))
            }
        }
    }

    /// Turn a frame payload into plaintext for this protocol version.
    private func decode(_ raw: Data) -> Data {
        switch version {
        case 3.5...:
            return TuyaCodec.stripPrefixes(raw, version: version)
        case 3.4:
            var p = raw
            if p.count % 16 == 4 { p = p.subdata(in: 4..<p.count) }
            guard let plain = TuyaCrypto.ecb(p, key: key, encrypt: false) else { return Data() }
            return TuyaCodec.stripPrefixes(plain, version: version)
        default:
            let p = TuyaCodec.stripPrefixes(raw, version: version)
            if p.first == UInt8(ascii: "{") { return p }
            return TuyaCrypto.ecb(p, key: key, encrypt: false) ?? Data()
        }
    }

    private static let noHeaderCmds: Set<TuyaCmd> = [.dpQuery, .dpQueryNew, .heartbeat, .sessStart, .sessResp, .sessFinish]

    private func write(_ cmd: TuyaCmd, json: [String: Any]) {
        guard let d = try? JSONSerialization.data(withJSONObject: json) else { return }
        write(cmd, raw: d)
    }

    /// Encrypt and frame `payload` for this version, then send.
    private func write(_ cmd: TuyaCmd, raw payload: Data) {
        guard let c = conn else { return }
        let header = Data("\(version)".utf8) + Data(count: 12)
        let needsHeader = !Self.noHeaderCmds.contains(cmd)
        var pkt: Data?
        switch version {
        case 3.5...:
            pkt = try? TuyaCodec.pack6699(seq: seq, cmd: cmd.rawValue, payload: needsHeader ? header + payload : payload,
                                          key: SymmetricKey(data: key))
        case 3.4:
            let plain = needsHeader ? header + payload : payload
            if let enc = TuyaCrypto.ecb(plain, key: key, encrypt: true) {
                pkt = TuyaCodec.pack55AA(seq: seq, cmd: cmd.rawValue, payload: enc, hmacKey: key)
            }
        default:
            if let enc = TuyaCrypto.ecb(payload, key: key, encrypt: true) {
                pkt = TuyaCodec.pack55AA(seq: seq, cmd: cmd.rawValue, payload: needsHeader ? header + enc : enc, hmacKey: nil)
            }
        }
        guard let pkt else { return }
        seq &+= 1
        c.send(content: pkt, completion: .contentProcessed { [weak self] e in
            if e != nil { self?.q.async { self?.fail("send") } }
        })
    }

    // MARK: session key negotiation (3.4 / 3.5)

    private func beginHandshake() {
        var n = Data(count: 16)
        _ = n.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        localNonce = n
        write(.sessStart, raw: n)
        q.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard let self, self.state == .connecting, self.conn != nil else { return }
            self.fail("handshake timeout (wrong key or version?)")
        }
    }

    private func finishHandshake(_ payload: Data) {
        var p = payload
        if p.count > 48, version >= 3.5 { p = p.subdata(in: 4..<p.count) }
        guard p.count >= 48 else { fail("bad session reply"); return }
        let remote = p.subdata(in: 0..<16)
        guard TuyaCrypto.hmac(localNonce, key: realKey) == p.subdata(in: 16..<48) else { fail("wrong local key"); return }
        write(.sessFinish, raw: TuyaCrypto.hmac(remote, key: realKey))
        let xored = Data(zip(localNonce, remote).map { $0 ^ $1 })
        if version >= 3.5 {
            guard let nonce = try? AES.GCM.Nonce(data: localNonce.subdata(in: 0..<12)),
                  let box = try? AES.GCM.seal(xored, using: SymmetricKey(data: realKey), nonce: nonce)
            else { fail("session key"); return }
            sessionKey = box.ciphertext
        } else {
            guard let k = TuyaCrypto.ecb(xored, key: realKey, encrypt: true, pad: false) else { fail("session key"); return }
            sessionKey = k
        }
        becameReady()
    }

    private func handle(cmd: UInt32, payload: Data) {
        switch TuyaCmd(rawValue: cmd) {
        case .sessResp:
            if state == .connecting { finishHandshake(payload) }
        case .dpQueryNew, .dpQuery, .status, .controlNew, .control:
            guard let obj = TuyaCodec.json(payload) else { return }
            let dps = (obj["dps"] as? [String: Any]) ?? ((obj["data"] as? [String: Any])?["dps"] as? [String: Any])
            if let dps, cmd == TuyaCmd.dpQueryNew.rawValue || cmd == TuyaCmd.dpQuery.rawValue, !statusWaiters.isEmpty {
                let w = statusWaiters; statusWaiters.removeAll()
                w.forEach { $0(dps) }
            }
        default:
            break
        }
    }

    private func startHeartbeat() {
        heartbeat?.cancel()
        let t = DispatchSource.makeTimerSource(queue: q)
        t.schedule(deadline: .now() + 7, repeating: 7)
        t.setEventHandler { [weak self] in
            guard let self else { return }
            self.write(.heartbeat, json: ["gwId": self.deviceID, "devId": self.deviceID])
        }
        t.resume()
        heartbeat = t
    }
}

// MARK: - LAN discovery

/// Tuya devices announce themselves on UDP 6666 (older, 0x55AA) and 6667 (encrypted, 0x55AA or 0x6699).
enum TuyaDiscovery {
    struct Found: Hashable { let id: String; let ip: String; let version: String }

    static let udpKeyData = Insecure.MD5.hash(data: Data("yGAdlopoPVldABfn".utf8)).withUnsafeBytes { Data($0) }

    static func decode(_ msg: Data) -> Found? {
        var obj: [String: Any]?
        if case .frame(let f, _) = TuyaCodec.unpack(msg, gcmKey: SymmetricKey(data: udpKeyData), hmacKey: nil) {
            if msg.readBE32(0) == TuyaCodec.prefix6699 {
                obj = TuyaCodec.json(f.payload)
            } else {
                var p = f.payload
                // Older devices (UDP 6666) send plain JSON after a 4-byte return code.
                if p.count > 4, p[p.startIndex + 4] == UInt8(ascii: "{") { p = p.subdata(in: 4..<p.count) }
                else if p.count % 16 == 4 { p = p.subdata(in: 4..<p.count) }
                obj = p.first == UInt8(ascii: "{") ? TuyaCodec.json(p) : TuyaCrypto.ecb(p, key: udpKeyData, encrypt: false).flatMap(TuyaCodec.json)
            }
        }
        guard let obj, let id = obj["gwId"] as? String, let ip = obj["ip"] as? String else { return nil }
        return Found(id: id, ip: ip, version: obj["version"] as? String ?? "3.3")
    }

    /// Listen for `timeout` seconds. `stop` lets a caller end early once it has what it needs.
    static func scan(timeout: TimeInterval = 8, stop: ((Set<Found>) -> Bool)? = nil, _ done: @escaping (Set<Found>) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            let fds = [6666, 6667].compactMap { port -> Int32? in
                let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
                guard fd >= 0 else { return nil }
                var one: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
                setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &one, socklen_t(MemoryLayout<Int32>.size))
                var tv = timeval(tv_sec: 0, tv_usec: 200_000)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var addr = sockaddr_in()
                addr.sin_family = sa_family_t(AF_INET)
                addr.sin_port = UInt16(port).bigEndian
                addr.sin_addr = in_addr(s_addr: INADDR_ANY)
                let ok = withUnsafePointer(to: &addr) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
                }
                if ok != 0 { close(fd); return nil }
                return fd
            }
            defer { fds.forEach { close($0) } }
            var found = Set<Found>()
            let end = Date().addingTimeInterval(timeout)
            var raw = [UInt8](repeating: 0, count: 4096)
            while Date() < end, !fds.isEmpty {
                for fd in fds {
                    let n = recv(fd, &raw, raw.count, 0)
                    if n > 0, let f = decode(Data(raw[0..<n])) { found.insert(f) }
                }
                if let stop, stop(found) { break }
            }
            done(found)
        }
    }

    /// Find one device's IP and version by its ID.
    static func find(deviceID: String, timeout: TimeInterval = 12, _ done: @escaping (Found?) -> Void) {
        scan(timeout: timeout, stop: { $0.contains { $0.id == deviceID } }) { all in
            done(all.first { $0.id == deviceID })
        }
    }
}
