import Foundation

let args = CommandLine.arguments

if let idx = args.firstIndex(of: "--save-report") {
    guard idx + 1 < args.count else {
        fputs("Usage: triage-cache --save-report \"<markdown>\"\n", stderr)
        exit(1)
    }
    saveReport(args[idx + 1])
    exit(0)
}

do {
    _ = try shell("which glab")
} catch {
    fputs("Error: glab CLI not found. Install: brew install glab\n", stderr)
    exit(1)
}

do {
    _ = try shell("glab auth status")
} catch {
    fputs("Error: glab authentication expired or invalid. Run: glab auth login\n", stderr)
    fputs("  \(error)\n", stderr)
    exit(1)
}

guard FileManager.default.fileExists(atPath: studioDir) else {
    fputs("Error: \(studioDir) not found\n", stderr)
    exit(1)
}

func fetchOrDie() -> (Snapshot, [Int: String]) {
    switch fetchAllData() {
    case .success(let snapshot, let issueDescriptions):
        return (snapshot, issueDescriptions)
    case .failure(let errors):
        fputs("Error: all data sources failed. Check glab authentication (glab auth status).\n", stderr)
        for e in errors { fputs("  - \(e)\n", stderr) }
        exit(1)
    }
}

let forceMode = args.contains("--force")

if forceMode {
    let (snapshot, descriptions) = fetchOrDie()
    let analysis = computeAnalysis(snapshot: snapshot, issueDescriptions: descriptions)
    print(formatFull(reason: "forced", snapshot: snapshot, analysis: analysis))
    writeCache(snapshot: snapshot)
    exit(0)
}

let reason = determineReason()

if reason != "cache_valid" {
    let (snapshot, descriptions) = fetchOrDie()
    let analysis = computeAnalysis(snapshot: snapshot, issueDescriptions: descriptions)
    print(formatFull(reason: reason, snapshot: snapshot, analysis: analysis))
    writeCache(snapshot: snapshot)
    exit(0)
}

let cache = readCache()!
let (snapshot, descriptions) = fetchOrDie()

let diff = computeDiff(cached: cache.snapshot, fresh: snapshot)
let ageMinutes = cacheAgeMinutes(cache)

if diff.hasPriorityLabelChange {
    let analysis = computeAnalysis(snapshot: snapshot, issueDescriptions: descriptions)
    print(formatFull(reason: "priority_labels_changed", snapshot: snapshot, analysis: analysis))
    writeCache(snapshot: snapshot)
} else if diff.isEmpty {
    print(formatNoChanges(ageMinutes: ageMinutes, report: cache.report, recommendation: cache.recommendation))
} else {
    print(formatDelta(ageMinutes: ageMinutes, diff: diff, report: cache.report, recommendation: cache.recommendation))
    writeCache(snapshot: snapshot)
}
