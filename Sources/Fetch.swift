import Foundation

// MARK: - Raw glab JSON shapes (file-private)

private struct RawMR: Decodable {
    let iid: Int
    let title: String
    let draft: Bool?
    let sourceBranch: String?
    let createdAt: String?
    let updatedAt: String?
    let webUrl: String?
    let labels: [String]?
    let detailedMergeStatus: String?
    let userNotesCount: Int?
    let hasConflicts: Bool?
    let reviewers: [Reviewer]?

    struct Reviewer: Decodable {
        let username: String
    }
}

private struct RawIssue: Decodable {
    let iid: Int
    let title: String
    let labels: [String]?
    let createdAt: String?
    let webUrl: String?
    let description: String?
}

// MARK: - Raw → Typed mapping (file-private)

private extension MR {
    init(from raw: RawMR) {
        self.init(
            iid: raw.iid,
            title: raw.title,
            draft: raw.draft,
            sourceBranch: raw.sourceBranch,
            createdAt: raw.createdAt,
            updatedAt: raw.updatedAt,
            webUrl: raw.webUrl,
            labels: raw.labels ?? [],
            detailedMergeStatus: raw.detailedMergeStatus,
            userNotesCount: raw.userNotesCount,
            hasConflicts: raw.hasConflicts,
            reviewerUsernames: raw.reviewers?.map { $0.username }
        )
    }
}

private extension Issue {
    init(from raw: RawIssue) {
        self.init(
            iid: raw.iid,
            title: raw.title,
            labels: raw.labels ?? [],
            createdAt: raw.createdAt,
            webUrl: raw.webUrl,
            description: raw.description.map { String($0.prefix(500)) }
        )
    }
}

// MARK: - JSON decoding helper

private func decodeArray<T: Decodable>(_ string: String) -> [T] {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode([T].self, from: data)) ?? []
}

// MARK: - Public fetch

func fetchAllData() -> (snapshot: Snapshot, failCount: Int) {
    let group = DispatchGroup()
    let fetchQueue = DispatchQueue(label: "com.triage.fetch", attributes: .concurrent)
    let resultQueue = DispatchQueue(label: "com.triage.results")

    var nonDraftMRs:    [MR] = []
    var draftMRs:       [MR] = []
    var sandcastleMRs:  [MR] = []
    var issuesList:     [Issue] = []
    var worktreesList:  [String] = []
    var mergedBranches: [String] = []
    var failCount = 0

    func fetch(_ command: String, warning: String, transform: @escaping (String) -> Void) {
        group.enter()
        fetchQueue.async {
            let (out, code) = shell(command, workingDirectory: studioDir)
            resultQueue.sync {
                if code == 0 {
                    transform(out)
                } else {
                    failCount += 1
                    fputs("Warning: \(warning)\n", stderr)
                }
            }
            group.leave()
        }
    }

    fetch("glab mr list --author=\(triageAuthor) --not-draft -F json --per-page 50",
          warning: "failed to fetch non-draft MRs") { out in
        nonDraftMRs = (decodeArray(out) as [RawMR]).map { MR(from: $0) }
    }

    fetch("glab mr list --author=\(triageAuthor) --draft -F json --per-page 50",
          warning: "failed to fetch draft MRs") { out in
        draftMRs = (decodeArray(out) as [RawMR]).map { MR(from: $0) }
    }

    fetch("glab mr list --author=\(triageAuthor) -F json --per-page 50 --repo ericmasiello/sandcastle-studio",
          warning: "failed to fetch sandcastle MRs") { out in
        sandcastleMRs = (decodeArray(out) as [RawMR]).map { MR(from: $0) }
    }

    fetch("glab issue list -O json --per-page 100",
          warning: "failed to fetch issues") { out in
        issuesList = (decodeArray(out) as [RawIssue]).map { Issue(from: $0) }
    }

    // Worktrees — directory listing, no JSON
    group.enter()
    fetchQueue.async {
        let worktreePath = (studioDir as NSString).appendingPathComponent(".worktrees")
        let (out, _) = shell("ls '\(worktreePath)' 2>/dev/null")
        let dirs = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        resultQueue.sync { worktreesList = dirs }
        group.leave()
    }

    // Merged branches — git output parsing, no JSON
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

    let snapshot = Snapshot(
        nonDraftMrs: nonDraftMRs,
        draftMrs: draftMRs,
        sandcastleMrs: sandcastleMRs,
        issues: issuesList,
        worktrees: worktreesList,
        mergedBranches: mergedBranches
    )

    return (snapshot, failCount)
}
