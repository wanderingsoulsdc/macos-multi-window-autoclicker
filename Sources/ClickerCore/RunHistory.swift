import Foundation
import OSLog

public struct RunRecord: Codable, Equatable, Sendable {
    public let time: Date
    public let message: String
    public let closesRun: Bool

    public init(time: Date = .now, message: String, closesRun: Bool = false) {
        self.time = time
        self.message = String(decoding: message.utf8.prefix(1_024), as: UTF8.self)
        self.closesRun = closesRun
    }
}

public struct RunHistory: Sendable {
    public static let visibleLimit = 100
    private static let sizeLimit: UInt64 = 1_048_576
    private static let io = DispatchQueue(label: "local.macwindowclicker.run-history", qos: .utility)
    private static let logger = Logger(subsystem: "local.macwindowclicker.app", category: "RunHistory")
    private let url: URL

    public init(url: URL) { self.url = url }

    public func recent() -> [RunRecord] {
        Self.io.sync { Array(read().reversed()) }
    }

    public func append(_ record: RunRecord) {
        Self.io.async {
            do { try write(record) }
            catch { Self.logger.error("Could not save run history to disk.") }
        }
    }

    public static func flush() { io.sync {} }

    private func read() -> [RunRecord] {
        guard let file = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return [] }
        let offset = size > Self.sizeLimit ? size - Self.sizeLimit : 0
        guard (try? file.seek(toOffset: offset)) != nil,
              let data = try? file.read(upToCount: Int(Self.sizeLimit)) else { return [] }
        let decoder = JSONDecoder()
        return data.split(separator: 0x0A).suffix(Self.visibleLimit)
            .compactMap { try? decoder.decode(RunRecord.self, from: $0) }
    }

    private func write(_ record: RunRecord) throws {
        let encoder = JSONEncoder()
        // A leading newline isolates a partial final record left by a crash.
        let line = try Data([0x0A]) + encoder.encode(record)
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
            try line.write(to: url, options: .atomic)
            return
        }
        let size = (try manager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.uint64Value ?? 0
        if size + UInt64(line.count) > Self.sizeLimit {
            var shortened = Data()
            for previous in read().suffix(Self.visibleLimit - 1) {
                shortened.append(0x0A)
                shortened.append(try encoder.encode(previous))
            }
            shortened.append(line)
            try shortened.write(to: url, options: .atomic)
        } else {
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            try file.write(contentsOf: line)
        }
    }
}
