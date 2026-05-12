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

let reason = determineReason()

if reason != "cache_valid" {
    let (snapshot, failCount) = fetchAllData()
    if failCount >= 4 {
        fputs("Error: multiple data sources failed. Check glab authentication (glab auth status).\n", stderr)
        exit(1)
    }
    outputFull(reason: reason, snapshot: snapshot)
    writeCache(snapshot: snapshot)
    exit(0)
}

let cache = readCache()!
let cachedSnapshot = cache["snapshot"] as? [String: Any] ?? [:]
let (freshSnapshot, failCount) = fetchAllData()

if failCount >= 4 {
    fputs("Error: multiple data sources failed. Check glab authentication (glab auth status).\n", stderr)
    exit(1)
}

let diff = computeDiff(cached: cachedSnapshot, fresh: freshSnapshot)
let ageMinutes = cacheAgeMinutes(cache)
let previousReport = cache["report"] as? String
let previousRecommendation = cache["recommendation"] as? String

if diff.hasPriorityLabelChange {
    outputFull(reason: "priority_labels_changed", snapshot: freshSnapshot)
    writeCache(snapshot: freshSnapshot)
} else if diff.isEmpty {
    outputNoChanges(ageMinutes: ageMinutes, report: previousReport, recommendation: previousRecommendation)
} else {
    outputDelta(ageMinutes: ageMinutes, diff: diff, report: previousReport, recommendation: previousRecommendation)
    writeCache(snapshot: freshSnapshot)
}

// MARK: - Output Formatters

func outputFull(reason: String, snapshot: [String: Any]) {
    print("MODE: FULL")
    print("REASON: \(reason)")
    print("")
    print("---RAW_DATA---")
    if let jsonData = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        print(jsonString)
    }
    print("---END_RAW_DATA---")
}

func outputNoChanges(ageMinutes: Int, report: String?, recommendation: String?) {
    print("MODE: NO_CHANGES")
    print("CACHE_AGE_MINUTES: \(ageMinutes)")
    print("")
    print("---PREVIOUS_REPORT---")
    print(report ?? "(no report cached)")
    print("---END_PREVIOUS_REPORT---")
    print("")
    print("PREVIOUS_RECOMMENDATION: \(recommendation ?? "(none)")")
}

func outputDelta(ageMinutes: Int, diff: DiffResult, report: String?, recommendation: String?) {
    print("MODE: DELTA")
    print("CACHE_AGE_MINUTES: \(ageMinutes)")
    print("CHANGES_SUMMARY: \(diff.summary)")
    print("")
    print("---CHANGES---")
    for change in diff.changes {
        print(change)
    }
    print("---END_CHANGES---")
    print("")
    print("---PREVIOUS_REPORT---")
    print(report ?? "(no report cached)")
    print("---END_PREVIOUS_REPORT---")
    print("")
    print("PREVIOUS_RECOMMENDATION: \(recommendation ?? "(none)")")
}
