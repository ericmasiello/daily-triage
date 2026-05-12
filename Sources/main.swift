import Foundation

let args = CommandLine.arguments

// --save-report: update cache with LLM-generated report
if let idx = args.firstIndex(of: "--save-report") {
    guard idx + 1 < args.count else {
        fputs("Usage: triage-cache --save-report \"<markdown>\"\n", stderr)
        exit(1)
    }
    saveReport(args[idx + 1])
    exit(0)
}

// Verify prerequisites
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
let (snapshot, failCount) = fetchAllData()

// If all glab commands failed, likely an auth/config issue
if failCount >= 4 {
    fputs("Error: multiple data sources failed. Check glab authentication (glab auth status).\n", stderr)
    exit(1)
}

// Output FULL mode
print("MODE: FULL")
print("REASON: \(reason)")
print("")
print("---RAW_DATA---")
if let jsonData = try? JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys]),
   let jsonString = String(data: jsonData, encoding: .utf8) {
    print(jsonString)
}
print("---END_RAW_DATA---")

// Persist cache to disk
writeCache(snapshot: snapshot)
