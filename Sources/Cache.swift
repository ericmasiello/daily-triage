import Foundation

// MARK: - JSON helpers

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

// MARK: - Cache operations

func readCache(config: Config) -> CacheEnvelope? {
    guard let data = FileManager.default.contents(atPath: config.cachePath),
          let cache = try? makeDecoder().decode(CacheEnvelope.self, from: data),
          cache.version == 2
    else {
        return nil
    }
    return cache
}

func writeCache(snapshot: Snapshot, recommendation: String? = nil, config: Config) {
    let fm = FileManager.default
    if !fm.fileExists(atPath: config.cacheDir) {
        try? fm.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
    }

    // Preserve report and its recommendation from a previous --save-report call.
    // When a report exists, its recommendation (extracted from the LLM output)
    // takes precedence over the auto-computed one.
    let existing = readCache(config: config)

    let cache = CacheEnvelope(
        version: 2,
        timestamp: ISO8601DateFormatter().string(from: Date()),
        ttlSeconds: Int(config.ttlSeconds),
        snapshot: snapshot,
        report: existing?.report,
        recommendation: existing?.report != nil ? existing?.recommendation : recommendation
    )

    guard let data = try? makeEncoder().encode(cache) else {
        fputs("Warning: failed to serialize cache JSON\n", stderr)
        return
    }
    do {
        try data.write(to: URL(fileURLWithPath: config.cachePath))
    } catch {
        fputs("Warning: failed to write cache file: \(error.localizedDescription)\n", stderr)
    }
}

// MARK: - Save report

enum SaveReportError: Error, CustomStringConvertible {
    case cacheNotFound(path: String)
    case cacheCorrupt(path: String)
    case serializationFailed
    case writeFailed(Error)

    var description: String {
        switch self {
        case let .cacheNotFound(path):
            "cache file not found at \(path) — run triage-cache first"
        case let .cacheCorrupt(path):
            "cache file corrupt at \(path) — run triage-cache first"
        case .serializationFailed:
            "failed to serialize updated cache"
        case let .writeFailed(error):
            "failed to write cache file: \(error.localizedDescription)"
        }
    }
}

func saveReport(_ reportText: String, config: Config) throws {
    guard let data = FileManager.default.contents(atPath: config.cachePath) else {
        throw SaveReportError.cacheNotFound(path: config.cachePath)
    }
    guard var cache = try? makeDecoder().decode(CacheEnvelope.self, from: data) else {
        throw SaveReportError.cacheCorrupt(path: config.cachePath)
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
        throw SaveReportError.serializationFailed
    }
    do {
        try updated.write(to: URL(fileURLWithPath: config.cachePath))
    } catch {
        throw SaveReportError.writeFailed(error)
    }
}

// MARK: - Cache metadata

func cacheAgeMinutes(_ cache: CacheEnvelope) -> Int {
    guard let date = ISO8601DateFormatter().date(from: cache.timestamp) else {
        return 0
    }
    return Int(Date().timeIntervalSince(date) / 60)
}

func determineReason(config: Config) -> String {
    guard FileManager.default.fileExists(atPath: config.cachePath) else {
        return "first_run"
    }
    guard let cache = readCache(config: config) else {
        try? FileManager.default.removeItem(atPath: config.cachePath)
        return "cache_corrupt"
    }
    if let date = ISO8601DateFormatter().date(from: cache.timestamp),
       Date().timeIntervalSince(date) > config.ttlSeconds {
        return "cache_expired"
    }
    return "cache_valid"
}
