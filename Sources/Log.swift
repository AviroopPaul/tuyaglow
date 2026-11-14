import Foundation

/// Debug log at ~/Library/Logs/TuyaGlow.log
private let logQ = DispatchQueue(label: "tuyaglow.log")
private let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/TuyaGlow.log")
func blog(_ s: String) {
    let line = "\(Date()) \(s)\n"
    logQ.async {
        if let h = try? FileHandle(forWritingTo: logURL) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: logURL) }
    }
}
