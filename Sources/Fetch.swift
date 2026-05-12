import Foundation

/// Fetch all 6 data sources in parallel. Returns the snapshot dictionary and a count of failures.
func fetchAllData() -> (snapshot: [String: Any], failCount: Int) {
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

    // 4. Issues (descriptions truncated to 500 chars)
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

    let snapshot: [String: Any] = [
        "non_draft_mrs":   nonDraftMRs,
        "draft_mrs":       draftMRs,
        "sandcastle_mrs":  sandcastleMRs,
        "issues":          issuesList,
        "worktrees":       worktreesList,
        "merged_branches": mergedBranches
    ]

    return (snapshot, failCount)
}
