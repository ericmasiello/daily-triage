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
    let state: String?
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
            state: raw.state,
            labels: raw.labels ?? [],
            createdAt: raw.createdAt,
            webUrl: raw.webUrl
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

enum FetchResult {
    case success(snapshot: Snapshot, issueDescriptions: [Int: String], allIssues: [Issue])
    case failure([Error])
}

func fetchAllData(config: Config, runShell: @escaping ShellRunner = shell) -> FetchResult {
    let group = DispatchGroup()
    let fetchQueue = DispatchQueue(label: "com.triage.fetch", attributes: .concurrent)
    let resultQueue = DispatchQueue(label: "com.triage.results")

    var nonDraftMRs:    [MR] = []
    var draftMRs:       [MR] = []
    var sandcastleMRs:  [MR] = []
    var issuesList:     [Issue] = []
    var allIssuesList:  [Issue] = []
    var issueDescriptions: [Int: String] = [:]
    var worktreesList:  [String] = []
    var mergedBranches: [String] = []
    var errors: [Error] = []

    func fetch(_ command: String, source: String, transform: @escaping (String) -> Void) {
        group.enter()
        fetchQueue.async {
            do {
                let out = try runShell(command, config.studioDir)
                resultQueue.sync { transform(out) }
            } catch {
                resultQueue.sync {
                    errors.append(error)
                    fputs("Warning: failed to fetch \(source) — \(error)\n", stderr)
                }
            }
            group.leave()
        }
    }

    fetch("glab mr list --author=\(config.triageAuthor) --not-draft -F json --per-page 50",
          source: "non-draft MRs") { out in
        nonDraftMRs = (decodeArray(out) as [RawMR]).map { MR(from: $0) }
    }

    fetch("glab mr list --author=\(config.triageAuthor) --draft -F json --per-page 50",
          source: "draft MRs") { out in
        draftMRs = (decodeArray(out) as [RawMR]).map { MR(from: $0) }
    }

    fetch("glab mr list --author=\(config.triageAuthor) -F json --per-page 50 --repo ericmasiello/sandcastle-studio",
          source: "sandcastle MRs") { out in
        sandcastleMRs = (decodeArray(out) as [RawMR]).map { MR(from: $0) }
    }

    fetch("glab issue list -O json --per-page 100 --all",
          source: "issues") { out in
        let rawIssues: [RawIssue] = decodeArray(out)
        allIssuesList = rawIssues.map { Issue(from: $0) }
        issuesList = allIssuesList.filter { ($0.state ?? "opened") == "opened" }
        for raw in rawIssues {
            if let desc = raw.description, !desc.isEmpty {
                issueDescriptions[raw.iid] = desc
            }
        }
    }

    // Non-fatal: worktree listing — empty result is fine if .worktrees doesn't exist
    group.enter()
    fetchQueue.async {
        let worktreePath = (config.studioDir as NSString).appendingPathComponent(".worktrees")
        let out = (try? runShell("ls '\(worktreePath)' 2>/dev/null", nil)) ?? ""
        let dirs = out.components(separatedBy: "\n").filter { !$0.isEmpty }
        resultQueue.sync { worktreesList = dirs }
        group.leave()
    }

    // Non-fatal: merged branch detection — falls back to empty list
    group.enter()
    fetchQueue.async {
        let rawDefault = (try? runShell(
            "git -C '\(config.studioDir)' symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'", nil)) ?? ""
        let defaultBranch = rawDefault.trimmingCharacters(in: .whitespacesAndNewlines)
        let branch = defaultBranch.isEmpty ? "master" : defaultBranch

        let branchOut = (try? runShell("git -C '\(config.studioDir)' branch -r --merged '\(branch)' 2>/dev/null", nil)) ?? ""
        let branches = branchOut
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.contains("->") }
        resultQueue.sync { mergedBranches = branches }
        group.leave()
    }

    group.wait()

    if errors.count >= 4 {
        return .failure(errors)
    }

    let worktreeSet = Set(worktreesList)
    let filteredBranches = mergedBranches.filter { branch in
        let name = branch
            .split(separator: "/", maxSplits: 1)
            .last
            .map(String.init) ?? branch
        return worktreeSet.contains(name)
    }

    let snapshot = Snapshot(
        nonDraftMrs: nonDraftMRs,
        draftMrs: draftMRs,
        sandcastleMrs: sandcastleMRs,
        issues: issuesList,
        worktrees: worktreesList,
        mergedBranches: filteredBranches
    )

    return .success(snapshot: snapshot, issueDescriptions: issueDescriptions, allIssues: allIssuesList)
}
