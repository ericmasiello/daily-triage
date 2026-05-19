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

let (_, glabExit) = shell("which glab")
if glabExit != 0 {
    fputs("Error: glab CLI not found. Install: brew install glab\n", stderr)
    exit(1)
}
guard FileManager.default.fileExists(atPath: studioDir) else {
    fputs("Error: \(studioDir) not found\n", stderr)
    exit(1)
}

let forceMode = args.contains("--force")

if forceMode {
    let (snapshot, failCount) = fetchAllData()
    if failCount >= 4 {
        fputs("Error: multiple data sources failed. Check glab authentication (glab auth status).\n", stderr)
        exit(1)
    }
    print(formatFull(reason: "forced", snapshot: snapshot))
    writeCache(snapshot: snapshot)
    exit(0)
}

let reason = determineReason()

if reason != "cache_valid" {
    let (snapshot, failCount) = fetchAllData()
    if failCount >= 4 {
        fputs("Error: multiple data sources failed. Check glab authentication (glab auth status).\n", stderr)
        exit(1)
    }
    print(formatFull(reason: reason, snapshot: snapshot))
    writeCache(snapshot: snapshot)
    exit(0)
}

let cache = readCache()!
let (freshSnapshot, failCount) = fetchAllData()

if failCount >= 4 {
    fputs("Error: multiple data sources failed. Check glab authentication (glab auth status).\n", stderr)
    exit(1)
}

let diff = computeDiff(cached: cache.snapshot, fresh: freshSnapshot)
let ageMinutes = cacheAgeMinutes(cache)

if diff.hasPriorityLabelChange {
    print(formatFull(reason: "priority_labels_changed", snapshot: freshSnapshot))
    writeCache(snapshot: freshSnapshot)
} else if diff.isEmpty {
    print(formatNoChanges(ageMinutes: ageMinutes, report: cache.report, recommendation: cache.recommendation))
} else {
    print(formatDelta(ageMinutes: ageMinutes, diff: diff, report: cache.report, recommendation: cache.recommendation))
    writeCache(snapshot: freshSnapshot)
}
