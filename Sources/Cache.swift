import Foundation

let cacheDir: String = {
    if let dir = ProcessInfo.processInfo.environment["TRIAGE_CACHE_DIR"] {
        return dir
    }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".cache/eric-triage")
}()
let cachePath: String = (cacheDir as NSString).appendingPathComponent("last-run.json")
let studioDir: String = {
    if let dir = ProcessInfo.processInfo.environment["TRIAGE_STUDIO_DIR"] {
        return dir
    }
    return (NSHomeDirectory() as NSString).appendingPathComponent("Sites/studio")
}()
let ttlSeconds: TimeInterval = 3600
let triageAuthor: String = ProcessInfo.processInfo.environment["TRIAGE_AUTHOR"] ?? "ericmasiello"

private func makeDecoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.keyDecodingStrategy = .convertFromSnakeCase
    return d
}

private func makeEncoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.keyEncodingStrategy = .convertToSnakeCase
    return e
}

func readCache() -> CacheEnvelope? {
    guard let data = FileManager.default.contents(atPath: cachePath),
          let cache = try? makeDecoder().decode(CacheEnvelope.self, from: data),
          cache.version == 2 else {
        return nil
    }
    return cache
}

func writeCache(snapshot: Snapshot) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: cacheDir) {
        try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    }

    let cache = CacheEnvelope(
        version: 2,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        ttlSeconds: Int(ttlSeconds),
        snapshot: snapshot,
        report: nil,
        recommendation: nil,
        todoist: nil
    )

    guard let data = try? makeEncoder().encode(cache) else {
        fputs("Warning: failed to serialize cache JSON\n", stderr)
        return
    }
    try? data.write(to: URL(fileURLWithPath: cachePath))
}

func saveReport(_ reportText: String) {
    guard let data = FileManager.default.contents(atPath: cachePath) else {
        fputs("Error: cache file not found or corrupt at \(cachePath)\nRun triage-cache first.\n", stderr)
        exit(1)
    }
    guard var cache = try? makeDecoder().decode(CacheEnvelope.self, from: data) else {
        fputs("Error: cache file not found or corrupt at \(cachePath)\nRun triage-cache first.\n", stderr)
        exit(1)
    }

    var recommendation: String? = nil
    for line in reportText.components(separatedBy: "\n").reversed() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().contains("my recommendation:") {
            recommendation = trimmed
            break
        }
    }

    cache.report = reportText
    cache.recommendation = recommendation

    guard let updated = try? makeEncoder().encode(cache) else {
        fputs("Error: failed to serialize updated cache\n", stderr)
        exit(1)
    }
    do {
        try updated.write(to: URL(fileURLWithPath: cachePath))
    } catch {
        fputs("Error: failed to write cache file: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
}

func cacheAgeMinutes(_ cache: CacheEnvelope) -> Int {
    guard let date = ISO8601DateFormatter().date(from: cache.timestamp) else {
        return 0
    }
    return Int(Date().timeIntervalSince(date) / 60)
}

func determineReason() -> String {
    guard FileManager.default.fileExists(atPath: cachePath) else {
        return "first_run"
    }
    guard let cache = readCache() else {
        try? FileManager.default.removeItem(atPath: cachePath)
        return "cache_corrupt"
    }
    if let date = ISO8601DateFormatter().date(from: cache.timestamp),
       Date().timeIntervalSince(date) > ttlSeconds {
        return "cache_expired"
    }
    return "cache_valid"
}
