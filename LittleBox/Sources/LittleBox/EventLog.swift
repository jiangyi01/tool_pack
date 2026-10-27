import Foundation

/// A small rolling log of what LittleBox did with each item (~/Library/Logs/LittleBox/events.log),
/// so problems can be diagnosed after the fact without needing to reproduce them live.
enum EventLog {
    private static let queue = DispatchQueue(label: "littlebox.log", qos: .utility)
    private static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/LittleBox/events.log")

    static func write(_ line: String) {
        let stamp = ISO8601DateFormatter.string(from: Date(), timeZone: .current,
                                                formatOptions: [.withTime, .withColonSeparatorInTime, .withFractionalSeconds])
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 512_000 {
                try? fm.removeItem(at: url)
            }
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(data)
                try? h.close()
            } else {
                try? data.write(to: url)
            }
        }
    }
}
