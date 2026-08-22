import Foundation

// MARK: - GitLab Service

struct GitLabService: DataSourceService {
    let label = "gitlab"
    let failurePolicy: FailurePolicy = .fatal

    struct State: Codable, Equatable {
        var nonDraftMrs: [MR]
        var draftMrs: [MR]
        var sandcastleMrs: [MR]
        var reviewerMrs: [MR]
        var assignedMrs: [MR]
        var worktrees: [String]
        var mergedBranches: [String]
    }

    private(set) var fetchedState: State?

    // MARK: - Protocol: fetch

    mutating func fetch(config: Config, shell: @escaping ShellRunner) async throws {
        let outputs = await fetchAllGitLab(config: config, shell: shell)
        let parsed = try parseFetchOutputs(outputs)

        let repoPaths = collectRepoPaths(
            parsed.nonDraftMRs,
            parsed.draftMRs,
            parsed.sandcastleMRs,
            parsed.reviewerMRs,
            parsed.assignedMRs
        )
        let archivedRepoPaths = await fetchArchivedRepoPaths(repoPaths, shell: shell)

        let worktreeSet = Set(parsed.worktrees)
        let filteredBranches = parsed.mergedBranches.filter { branch in
            let name = branch.split(separator: "/", maxSplits: 1).last.map(String.init) ?? branch
            return worktreeSet.contains(name)
        }

        fetchedState = State(
            nonDraftMrs: filterArchivedMRs(parsed.nonDraftMRs, archivedRepoPaths: archivedRepoPaths),
            draftMrs: filterArchivedMRs(parsed.draftMRs, archivedRepoPaths: archivedRepoPaths),
            sandcastleMrs: filterArchivedMRs(parsed.sandcastleMRs, archivedRepoPaths: archivedRepoPaths),
            reviewerMrs: filterArchivedMRs(parsed.reviewerMRs, archivedRepoPaths: archivedRepoPaths),
            assignedMrs: filterArchivedMRs(parsed.assignedMRs, archivedRepoPaths: archivedRepoPaths),
            worktrees: parsed.worktrees,
            mergedBranches: filteredBranches
        )
    }

    // MARK: - Protocol: diff

    func diff(cached: Snapshot, fresh: Snapshot) -> (changes: [String], signals: [DiffSignal]) {
        let old = cached.gitlab
        let new = fresh.gitlab

        var changes: [String] = []

        diffMRs(&changes, label: "MR", cached: old.nonDraftMrs, fresh: new.nonDraftMrs)
        diffMRs(&changes, label: "Draft MR", cached: old.draftMrs, fresh: new.draftMrs)
        diffMRs(&changes, label: "Sandcastle MR", cached: old.sandcastleMrs, fresh: new.sandcastleMrs)
        diffMRs(&changes, label: "Reviewer MR", cached: old.reviewerMrs, fresh: new.reviewerMrs)
        diffMRs(&changes, label: "Assigned MR", cached: old.assignedMrs, fresh: new.assignedMrs)
        diffStringSet(&changes, label: "Worktree", cached: old.worktrees, fresh: new.worktrees)
        diffStringSet(&changes, label: "Merged branch", cached: old.mergedBranches, fresh: new.mergedBranches)

        return (changes, [])
    }

    // MARK: - Protocol: format

    /// Cross-service analysis (tier_1_mrs, review_queue, stale_worktrees, the Jira-backed
    /// tier_2/tier_3 issue tiers, and the recommendation) blends this service's MR data with
    /// JiraService's issue data — it lives in Analysis.swift and is emitted once from
    /// App.swift, not per-service.
    func format(_: Snapshot) -> [String] {
        []
    }
}

// MARK: - Fetch Error

enum GitLabFetchError: Error, CustomStringConvertible {
    case tooManyFailures([String])

    var description: String {
        switch self {
        case let .tooManyFailures(errors):
            "all GitLab data sources failed: \(errors.joined(separator: ", "))"
        }
    }
}

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
    let references: References?

    struct Reviewer: Decodable {
        let username: String
    }

    struct References: Decodable {
        let full: String?
    }
}

// MARK: - Raw → Typed mapping

private func mapRawMR(_ raw: RawMR) -> MR {
    let repoPath = raw.references?.full.map { full -> String in
        // Strip the trailing "!<iid>" to get just the repo path.
        // e.g. "vistaprint-org/design-technology/studio/studio!12283" →
        // "vistaprint-org/design-technology/studio/studio"
        if let bang = full.lastIndex(of: "!") {
            return String(full[full.startIndex ..< bang])
        }
        return full
    }
    return MR(
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
        reviewerUsernames: raw.reviewers?.map(\.username),
        repoPath: repoPath
    )
}

// MARK: - JSON decoding

private func decodeArray<T: Decodable>(_ string: String) -> [T] {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode([T].self, from: data)) ?? []
}

// MARK: - Fetch internals

private enum FetchOutput: Sendable {
    case nonDraftMRs([MR])
    case draftMRs([MR])
    case sandcastleMRs([MR])
    case reviewerMRs([MR])
    case assignedMRs([MR])
    case worktrees([String])
    case mergedBranches([String])
    case failed(String)
}

private func fetchSource(
    _ command: String,
    dir: String?,
    label: String,
    runShell: ShellRunner,
    transform: (String) -> FetchOutput
) -> FetchOutput {
    do {
        let out = try runShell(command, dir)
        return transform(out)
    } catch {
        fputs("Warning: failed to fetch \(label) — \(error)\n", stderr)
        return .failed("\(error)")
    }
}

private struct ParsedFetchOutputs {
    var nonDraftMRs: [MR] = []
    var draftMRs: [MR] = []
    var sandcastleMRs: [MR] = []
    var reviewerMRs: [MR] = []
    var assignedMRs: [MR] = []
    var worktrees: [String] = []
    var mergedBranches: [String] = []

    mutating func apply(_ output: FetchOutput, errors: inout [String]) {
        switch output {
        case let .nonDraftMRs(mrs): nonDraftMRs = mrs
        case let .draftMRs(mrs): draftMRs = mrs
        case let .sandcastleMRs(mrs): sandcastleMRs = mrs
        case let .reviewerMRs(mrs): reviewerMRs = mrs
        case let .assignedMRs(mrs): assignedMRs = mrs
        case let .worktrees(dirs): worktrees = dirs
        case let .mergedBranches(branches): mergedBranches = branches
        case let .failed(desc): errors.append(desc)
        }
    }
}

private func parseFetchOutputs(_ outputs: [FetchOutput]) throws -> ParsedFetchOutputs {
    var parsed = ParsedFetchOutputs()
    var errors: [String] = []
    for output in outputs {
        parsed.apply(output, errors: &errors)
    }
    // Six concurrent sub-fetches today (5 MR queries + worktrees/branches counted together
    // below). Bail out once too little GitLab signal remains to trust the result, rather
    // than silently reporting a partial/misleading snapshot.
    if errors.count >= 4 {
        throw GitLabFetchError.tooManyFailures(errors)
    }
    return parsed
}

private func fetchAllGitLab(config: Config, shell: @escaping ShellRunner) async -> [FetchOutput] {
    await withTaskGroup(of: FetchOutput.self) { group in
        group.addTask {
            fetchSource(
                "glab mr list --author=\(config.triageAuthor) --not-draft -F json --per-page 50",
                dir: config.studioDir,
                label: "non-draft MRs",
                runShell: shell
            ) { out in
                .nonDraftMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            fetchSource(
                "glab mr list --author=\(config.triageAuthor) --draft -F json --per-page 50",
                dir: config.studioDir,
                label: "draft MRs",
                runShell: shell
            ) { out in
                .draftMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            let author = config.triageAuthor
            let cmd = "glab mr list --author=\(author) -F json --per-page 50 --repo ericmasiello/sandcastle-studio"
            return fetchSource(cmd, dir: config.studioDir, label: "sandcastle MRs", runShell: shell) { out in
                .sandcastleMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            let author = config.triageAuthor
            let cmd =
                "glab api \"merge_requests?scope=all&reviewer_username=\(author)&state=opened&per_page=100\""
            return fetchSource(cmd, dir: nil, label: "reviewer MRs", runShell: shell) { out in
                .reviewerMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            let author = config.triageAuthor
            let cmd =
                "glab api \"merge_requests?scope=all&assignee_username=\(author)&state=opened&per_page=100\""
            return fetchSource(cmd, dir: nil, label: "assigned MRs", runShell: shell) { out in
                .assignedMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            let worktreePath = (config.studioDir as NSString).appendingPathComponent(".worktrees")
            let out = (try? shell("ls '\(worktreePath)' 2>/dev/null", nil)) ?? ""
            let dirs = out.components(separatedBy: "\n").filter { !$0.isEmpty }
            return .worktrees(dirs)
        }

        group.addTask {
            let dir = config.studioDir
            let symrefCmd = "git -C '\(dir)' symbolic-ref refs/remotes/origin/HEAD 2>/dev/null"
                + " | sed 's@^refs/remotes/origin/@@'"
            let rawDefault = (try? shell(symrefCmd, nil)) ?? ""
            let defaultBranch = rawDefault.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = defaultBranch.isEmpty ? "master" : defaultBranch

            let branchOut = (try? shell(
                "git -C '\(config.studioDir)' branch -r --merged '\(branch)' 2>/dev/null",
                nil
            )) ?? ""
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
}

// MARK: - Diff internals

private func diffMRs(_ changes: inout [String], label: String, cached: [MR], fresh: [MR]) {
    let cachedByIID = Dictionary(cached.map { ($0.iid, $0) }) { _, latest in latest }
    let freshByIID = Dictionary(fresh.map { ($0.iid, $0) }) { _, latest in latest }

    let cachedIIDs = Set(cachedByIID.keys)
    let freshIIDs = Set(freshByIID.keys)

    for iid in freshIIDs.subtracting(cachedIIDs).sorted() {
        changes.append("\(label) !\(iid): added (\(freshByIID[iid]!.title))")
    }

    for iid in cachedIIDs.subtracting(freshIIDs).sorted() {
        changes.append("\(label) !\(iid): removed (\(cachedByIID[iid]!.title))")
    }

    for iid in cachedIIDs.intersection(freshIIDs).sorted() {
        let old = cachedByIID[iid]!
        let new = freshByIID[iid]!

        if old.detailedMergeStatus != new.detailedMergeStatus {
            let from = old.detailedMergeStatus ?? "null"
            let to = new.detailedMergeStatus ?? "null"
            changes.append("\(label) !\(iid): detailed_merge_status changed \(from) → \(to)")
        }
        if old.hasConflicts != new.hasConflicts {
            let from = describeOptional(old.hasConflicts)
            let to = describeOptional(new.hasConflicts)
            changes.append("\(label) !\(iid): has_conflicts changed \(from) → \(to)")
        }
        if old.userNotesCount != new.userNotesCount {
            let from = describeOptional(old.userNotesCount)
            let to = describeOptional(new.userNotesCount)
            changes.append("\(label) !\(iid): user_notes_count changed \(from) → \(to)")
        }
        if old.labels != new.labels {
            let from = old.labels.joined(separator: ", ")
            let to = new.labels.joined(separator: ", ")
            changes.append("\(label) !\(iid): labels changed [\(from)] → [\(to)]")
        }
    }
}

private func diffStringSet(
    _ changes: inout [String],
    label: String,
    cached: [String],
    fresh: [String]
) {
    let cachedSet = Set(cached)
    let freshSet = Set(fresh)

    for item in freshSet.subtracting(cachedSet).sorted() {
        changes.append("\(label): added \(item)")
    }
    for item in cachedSet.subtracting(freshSet).sorted() {
        changes.append("\(label): removed \(item)")
    }
}

private func describeOptional(_ value: (some Any)?) -> String {
    guard let value else { return "null" }
    return "\(value)"
}
