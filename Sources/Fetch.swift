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
    case failure([String])
}

private enum FetchOutput: Sendable {
    case nonDraftMRs([MR])
    case draftMRs([MR])
    case sandcastleMRs([MR])
    case issues(open: [Issue], descriptions: [Int: String], all: [Issue])
    case worktrees([String])
    case mergedBranches([String])
    case failed(String)
}

private let defaultShell: ShellRunner = { command, dir in
    try shell(command, workingDirectory: dir)
}

func fetchAllData(config: Config, runShell: @escaping ShellRunner = defaultShell) async -> FetchResult {
    let outputs: [FetchOutput] = await withTaskGroup(of: FetchOutput.self) { group in
        group.addTask {
            do {
                let out = try runShell("glab mr list --author=\(config.triageAuthor) --not-draft -F json --per-page 50", config.studioDir)
                return .nonDraftMRs((decodeArray(out) as [RawMR]).map { MR(from: $0) })
            } catch {
                fputs("Warning: failed to fetch non-draft MRs — \(error)\n", stderr)
                return .failed("\(error)")
            }
        }

        group.addTask {
            do {
                let out = try runShell("glab mr list --author=\(config.triageAuthor) --draft -F json --per-page 50", config.studioDir)
                return .draftMRs((decodeArray(out) as [RawMR]).map { MR(from: $0) })
            } catch {
                fputs("Warning: failed to fetch draft MRs — \(error)\n", stderr)
                return .failed("\(error)")
            }
        }

        group.addTask {
            do {
                let out = try runShell("glab mr list --author=\(config.triageAuthor) -F json --per-page 50 --repo ericmasiello/sandcastle-studio", config.studioDir)
                return .sandcastleMRs((decodeArray(out) as [RawMR]).map { MR(from: $0) })
            } catch {
                fputs("Warning: failed to fetch sandcastle MRs — \(error)\n", stderr)
                return .failed("\(error)")
            }
        }

        group.addTask {
            do {
                let out = try runShell("glab issue list -O json --per-page 100 --all", config.studioDir)
                let rawIssues: [RawIssue] = decodeArray(out)
                let all = rawIssues.map { Issue(from: $0) }
                let open = all.filter { ($0.state ?? "opened") == "opened" }
                var descriptions: [Int: String] = [:]
                for raw in rawIssues {
                    if let desc = raw.description, !desc.isEmpty {
                        descriptions[raw.iid] = desc
                    }
                }
                return .issues(open: open, descriptions: descriptions, all: all)
            } catch {
                fputs("Warning: failed to fetch issues — \(error)\n", stderr)
                return .failed("\(error)")
            }
        }

        // Non-fatal: worktree listing — empty result is fine if .worktrees doesn't exist
        group.addTask {
            let worktreePath = (config.studioDir as NSString).appendingPathComponent(".worktrees")
            let out = (try? runShell("ls '\(worktreePath)' 2>/dev/null", nil)) ?? ""
            let dirs = out.components(separatedBy: "\n").filter { !$0.isEmpty }
            return .worktrees(dirs)
        }

        // Non-fatal: merged branch detection — falls back to empty list
        group.addTask {
            let rawDefault = (try? runShell(
                "git -C '\(config.studioDir)' symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'", nil)) ?? ""
            let defaultBranch = rawDefault.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = defaultBranch.isEmpty ? "master" : defaultBranch

            let branchOut = (try? runShell("git -C '\(config.studioDir)' branch -r --merged '\(branch)' 2>/dev/null", nil)) ?? ""
            let branches = branchOut
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("->") }
            return .mergedBranches(branches)
        }

        var results: [FetchOutput] = []
        for await output in group {
            results.append(output)
        }
        return results
    }

    var nonDraftMRs:    [MR] = []
    var draftMRs:       [MR] = []
    var sandcastleMRs:  [MR] = []
    var issuesList:     [Issue] = []
    var allIssuesList:  [Issue] = []
    var issueDescriptions: [Int: String] = [:]
    var worktreesList:  [String] = []
    var mergedBranches: [String] = []
    var errors: [String] = []

    for output in outputs {
        switch output {
        case .nonDraftMRs(let mrs):    nonDraftMRs = mrs
        case .draftMRs(let mrs):       draftMRs = mrs
        case .sandcastleMRs(let mrs):  sandcastleMRs = mrs
        case .issues(let open, let descriptions, let all):
            issuesList = open
            issueDescriptions = descriptions
            allIssuesList = all
        case .worktrees(let dirs):     worktreesList = dirs
        case .mergedBranches(let b):   mergedBranches = b
        case .failed(let desc):        errors.append(desc)
        }
    }

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
