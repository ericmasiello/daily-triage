import Foundation

// MARK: - Constants

let cacheDir = (NSHomeDirectory() as NSString).appendingPathComponent(".cache/eric-triage")
let cachePath = (cacheDir as NSString).appendingPathComponent("last-run.json")
let studioDir = (NSHomeDirectory() as NSString).appendingPathComponent("Sites/studio")
let ttlSeconds: TimeInterval = 3600

// MARK: - Shell Execution

/// Runs a bash command, captures stdout, suppresses stderr.
/// Returns the trimmed stdout and the process exit code.
func shell(_ command: String, workingDirectory: String? = nil) -> (output: String, exitCode: Int32) {
    let process = Process()
    let outPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardOutput = outPipe
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")

    if let dir = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
    }

    do {
        try process.run()
    } catch {
        return ("", 1)
    }

    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
}

// MARK: - JSON Helpers

/// Parse a JSON string as an array of dictionaries. Returns empty array on failure.
func parseJSONArray(_ string: String) -> [[String: Any]] {
    guard !string.isEmpty,
          let data = string.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    return parsed
}

// MARK: - Data Extraction

/// Extract the fields needed for triage from MR JSON objects.
func extractMRFields(_ mrs: [[String: Any]]) -> [[String: Any]] {
    mrs.map { mr in
        var result: [String: Any] = [:]
        for key in ["iid", "title", "draft", "source_branch", "created_at", "updated_at",
                     "web_url", "labels", "detailed_merge_status", "user_notes_count", "has_conflicts"] {
            if let val = mr[key] { result[key] = val }
        }
        // Flatten reviewers to username strings
        if let reviewers = mr["reviewers"] as? [[String: Any]] {
            result["reviewer_usernames"] = reviewers.compactMap { $0["username"] as? String }
        }
        return result
    }
}

/// Extract issue fields, truncating descriptions to 500 chars.
func extractIssueFields(_ issues: [[String: Any]]) -> [[String: Any]] {
    issues.map { issue in
        var result: [String: Any] = [:]
        for key in ["iid", "title", "labels", "created_at", "web_url"] {
            if let val = issue[key] { result[key] = val }
        }
        let desc = (issue["description"] as? String) ?? ""
        result["description"] = String(desc.prefix(500))
        return result
    }
}

// MARK: - Cache Operations

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

// MARK: - Reason Determination

/// Determine why FULL mode is being triggered based on cache state.
func determineReason() -> String {
    guard FileManager.default.fileExists(atPath: cachePath) else {
        return "first_run"
    }
    guard let cache = readCache() else {
        return "cache_corrupt"
    }
    if let ts = cache["timestamp"] as? String,
       let date = ISO8601DateFormatter().date(from: ts),
       Date().timeIntervalSince(date) > ttlSeconds {
        return "cache_expired"
    }
    // Cache is valid and within TTL. In future phases this triggers diff logic
    // for NO_CHANGES/DELTA. Phase 0 always outputs FULL.
    return "cache_valid"
}

// MARK: - Main

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

// Fetch all 6 data sources in parallel via DispatchGroup
let group = DispatchGroup()
let fetchQueue = DispatchQueue(label: "com.triage.fetch", attributes: .concurrent)
let resultQueue = DispatchQueue(label: "com.triage.results")

var nonDraftMRs:    [[String: Any]] = []
var draftMRs:       [[String: Any]] = []
var sandcastleMRs:  [[String: Any]] = []
var issuesList:     [[String: Any]] = []
var worktreesList:  [String] = []
var mergedBranches: [String] = []
var failCount = 0

// 1. Non-draft MRs
group.enter()
fetchQueue.async {
    let (out, code) = shell(
        "glab mr list --author=ericmasiello --not-draft -F json --per-page 50",
        workingDirectory: studioDir)
    if code == 0 {
        let extracted = extractMRFields(parseJSONArray(out))
        resultQueue.sync { nonDraftMRs = extracted }
    } else {
        resultQueue.sync { failCount += 1 }
        fputs("Warning: failed to fetch non-draft MRs\n", stderr)
    }
    group.leave()
}

// 2. Draft MRs
group.enter()
fetchQueue.async {
    let (out, code) = shell(
        "glab mr list --author=ericmasiello --draft -F json --per-page 50",
        workingDirectory: studioDir)
    if code == 0 {
        let extracted = extractMRFields(parseJSONArray(out))
        resultQueue.sync { draftMRs = extracted }
    } else {
        resultQueue.sync { failCount += 1 }
        fputs("Warning: failed to fetch draft MRs\n", stderr)
    }
    group.leave()
}

// 3. Sandcastle MRs
group.enter()
fetchQueue.async {
    let (out, code) = shell(
        "glab mr list --author=ericmasiello -F json --per-page 50 --repo ericmasiello/sandcastle-studio",
        workingDirectory: studioDir)
    if code == 0 {
        let extracted = extractMRFields(parseJSONArray(out))
        resultQueue.sync { sandcastleMRs = extracted }
    } else {
        resultQueue.sync { failCount += 1 }
        fputs("Warning: failed to fetch sandcastle MRs\n", stderr)
    }
    group.leave()
}

// 4. Issues (descriptions truncated to 500 chars, matching current jq behavior)
group.enter()
fetchQueue.async {
    let (out, code) = shell(
        "glab issue list -O json --per-page 100",
        workingDirectory: studioDir)
    if code == 0 {
        let extracted = extractIssueFields(parseJSONArray(out))
        resultQueue.sync { issuesList = extracted }
    } else {
        resultQueue.sync { failCount += 1 }
        fputs("Warning: failed to fetch issues\n", stderr)
    }
    group.leave()
}

// 5. Worktree listing
group.enter()
fetchQueue.async {
    let worktreePath = (studioDir as NSString).appendingPathComponent(".worktrees")
    let (out, _) = shell("ls '\(worktreePath)' 2>/dev/null")
    let dirs = out.components(separatedBy: "\n").filter { !$0.isEmpty }
    resultQueue.sync { worktreesList = dirs }
    group.leave()
}

// 6. Merged branches
group.enter()
fetchQueue.async {
    // Detect default branch (master or main)
    let (rawDefault, _) = shell(
        "git -C '\(studioDir)' symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'")
    let defaultBranch = rawDefault.trimmingCharacters(in: .whitespacesAndNewlines)
    let branch = defaultBranch.isEmpty ? "master" : defaultBranch

    let (branchOut, _) = shell("git -C '\(studioDir)' branch -r --merged '\(branch)' 2>/dev/null")
    let branches = branchOut
        .components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty && !$0.contains("->") }
    resultQueue.sync { mergedBranches = branches }
    group.leave()
}

group.wait()

// If all glab commands failed, likely an auth/config issue
if failCount >= 4 {
    fputs("Error: multiple data sources failed. Check glab authentication (glab auth status).\n", stderr)
    exit(1)
}

// Build snapshot
let snapshot: [String: Any] = [
    "non_draft_mrs":   nonDraftMRs,
    "draft_mrs":       draftMRs,
    "sandcastle_mrs":  sandcastleMRs,
    "issues":          issuesList,
    "worktrees":       worktreesList,
    "merged_branches": mergedBranches
]

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
