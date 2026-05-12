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

/// Read cache file. Returns nil if missing, unreadable, or wrong schema version.
func readCache() -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: cachePath),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          json["version"] as? Int == 1 else {
        return nil
    }
    return json
}

/// Write a fresh cache file with the v1 schema. Report/recommendation start as null.
func writeCache(snapshot: [String: Any]) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: cacheDir) {
        try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)
    }

    let cache: [String: Any] = [
        "version": 1,
        "timestamp": ISO8601DateFormatter().string(from: Date()),
        "ttl_seconds": Int(ttlSeconds),
        "snapshot": snapshot,
        "report": NSNull(),
        "recommendation": NSNull()
    ]

    guard let data = try? JSONSerialization.data(withJSONObject: cache, options: [.prettyPrinted, .sortedKeys]) else {
        fputs("Warning: failed to serialize cache JSON\n", stderr)
        return
    }
    try? data.write(to: URL(fileURLWithPath: cachePath))
}

/// Update report and recommendation in an existing cache file.
func saveReport(_ reportText: String) {
    guard let data = FileManager.default.contents(atPath: cachePath),
          var cache = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        fputs("Error: cache file not found or corrupt at \(cachePath)\nRun triage-cache first.\n", stderr)
        exit(1)
    }

    // Extract recommendation — last line containing "recommendation:"
    var recommendation: String? = nil
    for line in reportText.components(separatedBy: "\n").reversed() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.lowercased().contains("my recommendation:") {
            recommendation = trimmed
            break
        }
    }

    cache["report"] = reportText
    cache["recommendation"] = recommendation as Any? ?? NSNull()

    guard let updated = try? JSONSerialization.data(withJSONObject: cache, options: [.prettyPrinted, .sortedKeys]) else {
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

func cacheAgeMinutes(_ cache: [String: Any]) -> Int {
    guard let ts = cache["timestamp"] as? String,
          let date = ISO8601DateFormatter().date(from: ts) else {
        return 0
    }
    return Int(Date().timeIntervalSince(date) / 60)
}

/// Determine why FULL mode is being triggered based on cache state.
func determineReason() -> String {
    guard FileManager.default.fileExists(atPath: cachePath) else {
        return "first_run"
    }
    guard let cache = readCache() else {
        try? FileManager.default.removeItem(atPath: cachePath)
        return "cache_corrupt"
    }
    if let ts = cache["timestamp"] as? String,
       let date = ISO8601DateFormatter().date(from: ts),
       Date().timeIntervalSince(date) > ttlSeconds {
        return "cache_expired"
    }
    return "cache_valid"
}
