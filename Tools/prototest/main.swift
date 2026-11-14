import Foundation

// Protocol check against a real bulb or Tools/fake_device.py.
//   prototest <deviceID> <ip> <localKey> <version>   connect, read, write, read back
//   prototest scan [seconds]                          list Tuya devices on the LAN
let a = CommandLine.arguments
let sem = DispatchSemaphore(value: 0)

if a.count >= 2, a[1] == "scan" {
    TuyaDiscovery.scan(timeout: a.count > 2 ? Double(a[2]) ?? 6 : 6) { found in
        for f in found.sorted(by: { $0.id < $1.id }) { print("found \(f.id) ip=\(f.ip) version=\(f.version)") }
        if found.isEmpty { print("found nothing") }
        sem.signal()
    }
    sem.wait()
    exit(0)
}
guard a.count == 5, let ver = Double(a[4]) else { print("usage: prototest id ip key version | scan [s]"); exit(2) }

let c = TuyaClient(deviceID: a[1], host: a[2], localKey: a[3], version: ver)
c.onState = { print("state:", $0) }
c.start()
for _ in 0..<60 where !c.isReady { Thread.sleep(forTimeInterval: 0.1) }
guard c.isReady else { print("FAIL: not ready"); exit(1) }

var before: [String: Any]?
c.queryStatus { before = $0; sem.signal() }
sem.wait()
print("status:", before ?? "nil")
guard before != nil else { print("FAIL: no status"); exit(1) }

c.send(dps: ["21": "colour", "24": "00f003e803e8"])
Thread.sleep(forTimeInterval: 0.5)
var after: [String: Any]?
c.queryStatus { after = $0; sem.signal() }
sem.wait()
print("after write:", after ?? "nil")
let ok = (after?["21"] as? String) == "colour" && (after?["24"] as? String) == "00f003e803e8"

// Put it back as it was.
if let b = before {
    var r: [String: Any] = [:]
    for k in ["20", "21", "22", "23", "24"] { if let v = b[k] { r[k] = v } }
    c.sendAndFlush(dps: r)
}
print(ok ? "OK" : "FAIL: write not applied")
exit(ok ? 0 : 1)
