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
        var issues: [Issue]
        var worktrees: [String]
        var mergedBranches: [String]
    }

    private(set) var fetchedState: State?
    private(set) var issueDescriptions: [Int: String] = [:]
    private(set) var allIssues: [Issue] = []
    private(set) var referenceDate: Date = .init()

    // MARK: - Protocol: fetch

    mutating func fetch(config: Config, shell: @escaping ShellRunner) async throws {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        if let parsedDate = formatter.date(from: config.todayDate) {
            referenceDate = parsedDate
        }

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
            issues: parsed.issues,
            worktrees: parsed.worktrees,
            mergedBranches: filteredBranches
        )
        issueDescriptions = parsed.descriptions
        allIssues = parsed.allIssues
    }

    // MARK: - Protocol: diff

    func diff(cached: Snapshot, fresh: Snapshot) -> (changes: [String], signals: [DiffSignal]) {
        let old = cached.gitlab
        let new = fresh.gitlab

        var changes: [String] = []
        var hasPriorityChange = false

        diffMRs(&changes, label: "MR", cached: old.nonDraftMrs, fresh: new.nonDraftMrs)
        diffMRs(&changes, label: "Draft MR", cached: old.draftMrs, fresh: new.draftMrs)
        diffMRs(&changes, label: "Sandcastle MR", cached: old.sandcastleMrs, fresh: new.sandcastleMrs)
        diffMRs(&changes, label: "Reviewer MR", cached: old.reviewerMrs, fresh: new.reviewerMrs)
        diffMRs(&changes, label: "Assigned MR", cached: old.assignedMrs, fresh: new.assignedMrs)
        diffIssues(
            &changes,
            hasPriorityChange: &hasPriorityChange,
            cached: old.issues,
            fresh: new.issues
        )
        diffStringSet(&changes, label: "Worktree", cached: old.worktrees, fresh: new.worktrees)
        diffStringSet(&changes, label: "Merged branch", cached: old.mergedBranches, fresh: new.mergedBranches)

        var signals: [DiffSignal] = []
        if hasPriorityChange {
            signals.append(.priorityChange)
        }

        return (changes, signals)
    }

    // MARK: - Protocol: format

    func format(_ snapshot: Snapshot) -> [String] {
        let analysis = computeAnalysis(
            snapshot: snapshot,
            issueDescriptions: issueDescriptions,
            allIssues: allIssues,
            referenceDate: referenceDate
        )

        var lines: [String] = []
        lines.append("---ANALYSIS---")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.keyEncodingStrategy = .convertToSnakeCase
        if let data = try? encoder.encode(analysis),
           let str = String(data: data, encoding: .utf8) {
            lines.append(str)
        }
        lines.append("---END_ANALYSIS---")
        return lines
    }

    func computeRecommendation(snapshot: Snapshot) -> String {
        let analysis = computeAnalysis(
            snapshot: snapshot,
            issueDescriptions: issueDescriptions,
            allIssues: allIssues,
            referenceDate: referenceDate
        )
        return analysis.recommendation
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

private struct RawIssue: Decodable {
    let iid: Int
    let title: String
    let state: String?
    let labels: [String]?
    let createdAt: String?
    let webUrl: String?
    let description: String?
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

private func mapRawIssue(_ raw: RawIssue) -> Issue {
    Issue(
        iid: raw.iid,
        title: raw.title,
        state: raw.state,
        labels: raw.labels ?? [],
        createdAt: raw.createdAt,
        webUrl: raw.webUrl
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
    case issues(open: [Issue], descriptions: [Int: String], all: [Issue])
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
    var issues: [Issue] = []
    var allIssues: [Issue] = []
    var descriptions: [Int: String] = [:]
    var worktrees: [String] = []
    var mergedBranches: [String] = []

    mutating func apply(_ output: FetchOutput, errors: inout [String]) {
        switch output {
        case let .nonDraftMRs(mrs): nonDraftMRs = mrs
        case let .draftMRs(mrs): draftMRs = mrs
        case let .sandcastleMRs(mrs): sandcastleMRs = mrs
        case let .reviewerMRs(mrs): reviewerMRs = mrs
        case let .assignedMRs(mrs): assignedMRs = mrs
        case let .issues(open, descs, all):
            issues = open
            descriptions = descs
            allIssues = all
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
    if errors.count >= 4 {
        throw GitLabFetchError.tooManyFailures(errors)
    }
    return parsed
}

private func fetchIssues(config: Config, shell: ShellRunner) -> FetchOutput {
    do {
        let out = try shell("glab issue list -O json --per-page 100 --all", config.studioDir)
        let rawIssues: [RawIssue] = decodeArray(out)
        let all = rawIssues.map { mapRawIssue($0) }
        let open = all.filter { ($0.state ?? "opened") == "opened" }
        var descriptions: [Int: String] = [:]
        for raw in rawIssues where raw.description != nil && !raw.description!.isEmpty {
            descriptions[raw.iid] = raw.description!
        }
        return .issues(open: open, descriptions: descriptions, all: all)
    } catch {
        fputs("Warning: failed to fetch issues — \(error)\n", stderr)
        return .failed("\(error)")
    }
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

        group.addTask { fetchIssues(config: config, shell: shell) }

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

private func diffIssues(
    _ changes: inout [String],
    hasPriorityChange: inout Bool,
    cached: [Issue],
    fresh: [Issue]
) {
    let cachedByIID = Dictionary(cached.map { ($0.iid, $0) }) { _, latest in latest }
    let freshByIID = Dictionary(fresh.map { ($0.iid, $0) }) { _, latest in latest }

    let cachedIIDs = Set(cachedByIID.keys)
    let freshIIDs = Set(freshByIID.keys)

    for iid in freshIIDs.subtracting(cachedIIDs).sorted() {
        changes.append("Issue #\(iid): added (\(freshByIID[iid]!.title))")
    }

    for iid in cachedIIDs.subtracting(freshIIDs).sorted() {
        changes.append("Issue #\(iid): removed (\(cachedByIID[iid]!.title))")
    }

    for iid in cachedIIDs.intersection(freshIIDs).sorted() {
        let old = cachedByIID[iid]!
        let new = freshByIID[iid]!

        let oldLabels = Set(old.labels)
        let newLabels = Set(new.labels)

        if oldLabels != newLabels {
            let added = newLabels.subtracting(oldLabels)
            let removed = oldLabels.subtracting(newLabels)

            if added.contains(where: { $0.hasPrefix("p::") }) || removed.contains(where: { $0.hasPrefix("p::") }) {
                hasPriorityChange = true
            }

            var parts: [String] = []
            if !added.isEmpty {
                parts.append("added \(added.sorted().joined(separator: ", "))")
            }
            if !removed.isEmpty {
                parts.append("removed \(removed.sorted().joined(separator: ", "))")
            }
            changes.append("Issue #\(iid): labels \(parts.joined(separator: "; "))")
        }
    }

    for iid in freshIIDs.subtracting(cachedIIDs)
        where freshByIID[iid]!.labels.contains(where: { $0.hasPrefix("p::") }) {
        hasPriorityChange = true
    }
    for iid in cachedIIDs.subtracting(freshIIDs)
        where cachedByIID[iid]!.labels.contains(where: { $0.hasPrefix("p::") }) {
        hasPriorityChange = true
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

// MARK: - Analysis internals

private struct AnalysisResult: Codable {
    let prdHierarchy: [PRDHierarchyEntry]
    let tier1Mrs: [Tier1MR]
    let reviewQueue: [ReviewQueueMR]
    let tier2Issues: [TierIssue]
    let tier3Issues: [TierIssue]
    let staleWorktrees: [StaleWorktree]
    let recommendation: String

    enum CodingKeys: String, CodingKey {
        case prdHierarchy = "prd_hierarchy"
        case tier1Mrs = "tier_1_mrs"
        case reviewQueue = "review_queue"
        case tier2Issues = "tier_2_issues"
        case tier3Issues = "tier_3_issues"
        case staleWorktrees = "stale_worktrees"
        case recommendation
    }
}

private struct Tier1MR: Codable {
    let iid: Int
    let title: String
    let reviewStatus: String
    let ageHours: Int
    let webUrl: String?
}

private struct ReviewQueueMR: Codable {
    let iid: Int
    let title: String
    let repo: String
    let role: String
    let ageHours: Int
    let webUrl: String?
}

private struct StaleWorktree: Codable {
    let path: String
    let reason: String
}

private struct TierIssue: Codable {
    let iid: Int
    let title: String
    let workstreamCompletion: Int?
    let priority: String?
    let reason: String
    let webUrl: String?
}

private struct PRDHierarchyEntry: Codable {
    let prdIid: Int
    let title: String
    let children: [ChildInfo]
    let completion: CompletionInfo
}

private struct ChildInfo: Codable {
    let iid: Int
    let state: String
}

private struct CompletionInfo: Codable {
    let closed: Int
    let total: Int
    let percentage: Int
}

private func computeAnalysis(
    snapshot: Snapshot,
    issueDescriptions: [Int: String],
    allIssues: [Issue],
    referenceDate: Date
) -> AnalysisResult {
    let issuesByIID = Dictionary(allIssues.map { ($0.iid, $0) }) { _, latest in latest }
    let entries = buildPRDHierarchy(issueDescriptions: issueDescriptions, issuesByIID: issuesByIID)
    let tiers = computeIssueTiers(openIssues: snapshot.issues, entries: entries)
    let tier2 = tiers.tier2
    let tier3 = tiers.tier3
    let childToPRDIid = tiers.childToPRDIid
    let tier1 = rankTier1MRs(snapshot.nonDraftMrs, referenceDate: referenceDate)
    let reviewQueue = buildReviewQueue(
        reviewerMrs: snapshot.reviewerMrs,
        assignedMrs: snapshot.assignedMrs,
        referenceDate: referenceDate
    )

    let mergedShortNames = Set(snapshot.mergedBranches.compactMap { branch -> String? in
        branch.split(separator: "/", maxSplits: 1).last.map(String.init)
    })
    let staleWorktrees: [StaleWorktree] = snapshot.worktrees
        .filter { mergedShortNames.contains($0) }
        .map { StaleWorktree(path: $0, reason: "branch_merged") }

    let recommendation = computeRecommendationString(
        tier1: tier1,
        tier2: tier2,
        tier3: tier3,
        childToPRDIid: childToPRDIid,
        issuesByIID: issuesByIID
    )

    return AnalysisResult(
        prdHierarchy: entries,
        tier1Mrs: tier1,
        reviewQueue: reviewQueue,
        tier2Issues: tier2,
        tier3Issues: tier3,
        staleWorktrees: staleWorktrees,
        recommendation: recommendation
    )
}

private func buildPRDHierarchy(
    issueDescriptions: [Int: String],
    issuesByIID: [Int: Issue]
) -> [PRDHierarchyEntry] {
    var parentToChildren: [Int: [Int]] = [:]
    for (iid, description) in issueDescriptions {
        for parentIID in parseParentReferences(description) {
            parentToChildren[parentIID, default: []].append(iid)
        }
    }

    return parentToChildren.keys.sorted().map { prdIID in
        let childIIDs = parentToChildren[prdIID]!.sorted()
        let title = issuesByIID[prdIID]?.title ?? "Unknown issue #\(prdIID)"
        let children: [ChildInfo] = childIIDs.map { childIID in
            let state = issuesByIID[childIID]?.state ?? "closed"
            return ChildInfo(iid: childIID, state: state)
        }
        let closedCount = children.filter { $0.state == "closed" }.count
        let total = children.count
        let percentage = total > 0 ? (closedCount * 100) / total : 0
        return PRDHierarchyEntry(
            prdIid: prdIID,
            title: title,
            children: children,
            completion: CompletionInfo(closed: closedCount, total: total, percentage: percentage)
        )
    }
}

private struct IssueTierResult {
    var tier2: [TierIssue]
    var tier3: [TierIssue]
    var childToPRDIid: [Int: Int]
}

private func computeIssueTiers(
    openIssues: [Issue],
    entries: [PRDHierarchyEntry]
) -> IssueTierResult {
    var childToCompletion: [Int: Int] = [:]
    var childToPRDIid: [Int: Int] = [:]
    for entry in entries {
        for child in entry.children {
            let existing = childToCompletion[child.iid] ?? -1
            if entry.completion.percentage > existing {
                childToCompletion[child.iid] = entry.completion.percentage
                childToPRDIid[child.iid] = entry.prdIid
            }
        }
    }

    let prdIIDs = Set(entries.map(\.prdIid))
    var tier2: [TierIssue] = []
    var tier3: [TierIssue] = []

    for issue in openIssues where !prdIIDs.contains(issue.iid) {
        let priority = issue.labels.first { $0.hasPrefix("p::") }
        if let completion = childToCompletion[issue.iid], completion >= 80 {
            tier2.append(TierIssue(
                iid: issue.iid,
                title: issue.title,
                workstreamCompletion: completion,
                priority: priority,
                reason: "near_complete_workstream",
                webUrl: issue.webUrl
            ))
        } else {
            tier3.append(TierIssue(
                iid: issue.iid,
                title: issue.title,
                workstreamCompletion: nil,
                priority: priority,
                reason: "remaining_by_value_age",
                webUrl: issue.webUrl
            ))
        }
    }

    let sortByPriority = { (lhs: TierIssue, rhs: TierIssue) -> Bool in
        let rankLhs = priorityRank(lhs.priority)
        let rankRhs = priorityRank(rhs.priority)
        return rankLhs != rankRhs ? rankLhs < rankRhs : lhs.iid < rhs.iid
    }
    tier2.sort(by: sortByPriority)
    tier3.sort(by: sortByPriority)

    return IssueTierResult(tier2: tier2, tier3: tier3, childToPRDIid: childToPRDIid)
}

private func rankTier1MRs(_ mrs: [MR], referenceDate: Date) -> [Tier1MR] {
    let isoFormatter = ISO8601DateFormatter()
    var tier1: [Tier1MR] = mrs.map { mr in
        let status = reviewStatus(for: mr)
        let ageHours: Int = if let created = mr.createdAt,
                               let createdDate = isoFormatter.date(from: created) {
            max(0, Int(referenceDate.timeIntervalSince(createdDate) / 3600))
        } else {
            0
        }
        return Tier1MR(iid: mr.iid, title: mr.title, reviewStatus: status, ageHours: ageHours, webUrl: mr.webUrl)
    }
    tier1.sort { lhs, rhs in
        let rankLhs = reviewStatusRank(lhs.reviewStatus)
        let rankRhs = reviewStatusRank(rhs.reviewStatus)
        return rankLhs != rankRhs ? rankLhs < rankRhs : lhs.ageHours > rhs.ageHours
    }
    return tier1
}

private func buildReviewQueue(
    reviewerMrs: [MR],
    assignedMrs: [MR],
    referenceDate: Date
) -> [ReviewQueueMR] {
    let isoFormatter = ISO8601DateFormatter()
    var byURL: [String: ReviewQueueMR] = [:]

    let enqueue = { (mr: MR, role: String) in
        let key = mr.webUrl ?? "\(mr.iid)"
        let ageHours: Int = if let created = mr.createdAt,
                               let createdDate = isoFormatter.date(from: created) {
            max(0, Int(referenceDate.timeIntervalSince(createdDate) / 3600))
        } else {
            0
        }
        if let existing = byURL[key] {
            byURL[key] = ReviewQueueMR(
                iid: existing.iid,
                title: existing.title,
                repo: existing.repo,
                role: "reviewer+assignee",
                ageHours: existing.ageHours,
                webUrl: existing.webUrl
            )
        } else {
            byURL[key] = ReviewQueueMR(
                iid: mr.iid,
                title: mr.title,
                repo: mr.repoPath ?? "unknown",
                role: role,
                ageHours: ageHours,
                webUrl: mr.webUrl
            )
        }
    }

    for mr in reviewerMrs { enqueue(mr, "reviewer") }
    for mr in assignedMrs { enqueue(mr, "assignee") }

    return byURL.values.sorted { lhs, rhs in lhs.ageHours > rhs.ageHours }
}

// MARK: - Description parsing

private func reviewStatus(for mr: MR) -> String {
    let approved = mr.detailedMergeStatus == "approved" || mr.detailedMergeStatus == "mergeable"
    if approved {
        return "approved"
    }
    if (mr.userNotesCount ?? 0) > 0 {
        return "changes_requested"
    }
    return "awaiting_review"
}

private func reviewStatusRank(_ status: String) -> Int {
    switch status {
    case "changes_requested": 0
    case "awaiting_review": 1
    case "approved": 2
    default: 3
    }
}

private func computeRecommendationString(
    tier1: [Tier1MR],
    tier2: [TierIssue],
    tier3: [TierIssue],
    childToPRDIid: [Int: Int],
    issuesByIID: [Int: Issue]
) -> String {
    if let mr = tier1.first(where: { $0.reviewStatus == "changes_requested" }) {
        return "Address review feedback on MR !\(mr.iid)"
    }
    if let mr = tier1.first(where: { $0.reviewStatus == "awaiting_review" }) {
        return "Follow up on MR !\(mr.iid) review"
    }
    if let issue = tier2.first {
        let prdTitle: String = if let prdIid = childToPRDIid[issue.iid],
                                  let prd = issuesByIID[prdIid] {
            prd.title
        } else {
            "work stream"
        }
        let pct = issue.workstreamCompletion ?? 0
        return "Complete near-done work stream: \(prdTitle) (\(pct)%)"
    }
    if let issue = tier3.first {
        return "Work on #\(issue.iid): \(issue.title)"
    }
    return "No actionable items"
}

private func priorityRank(_ label: String?) -> Int {
    switch label {
    case "p::1": 0
    case "p::2": 1
    case "p::3": 2
    default: 3
    }
}

private func parseParentReferences(_ description: String) -> [Int] {
    var parents: [Int] = []
    let lines = description.components(separatedBy: "\n")

    var inParentPRDSection = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("## Parent PRD") {
            inParentPRDSection = true
            for iid in extractIIDs(from: trimmed, afterPrefix: "## Parent PRD") {
                parents.append(iid)
            }
            continue
        }

        if trimmed.hasPrefix("##") {
            inParentPRDSection = false
            continue
        }

        if inParentPRDSection {
            for iid in extractAllIIDs(from: trimmed) {
                parents.append(iid)
            }
            continue
        }

        if let range = trimmed.range(of: "Related to #", options: .caseInsensitive) {
            let afterHash = trimmed[range.upperBound...]
            if let iid = parseLeadingInt(String(afterHash)) {
                parents.append(iid)
            }
        }
    }

    var seen = Set<Int>()
    return parents.filter { seen.insert($0).inserted }
}

private func extractIIDs(from line: String, afterPrefix prefix: String) -> [Int] {
    guard let range = line.range(of: prefix) else { return [] }
    let remainder = String(line[range.upperBound...])
    return extractAllIIDs(from: remainder)
}

private func extractAllIIDs(from text: String) -> [Int] {
    var results: [Int] = []
    var i = text.startIndex

    while i < text.endIndex {
        if text[i] == "#" {
            let afterHash = text.index(after: i)
            if afterHash < text.endIndex {
                var end = afterHash
                while end < text.endIndex && text[end].isNumber {
                    end = text.index(after: end)
                }
                if end > afterHash, let iid = Int(text[afterHash ..< end]) {
                    results.append(iid)
                    i = end
                    continue
                }
            }
        }
        i = text.index(after: i)
    }

    return results
}

private func parseLeadingInt(_ str: String) -> Int? {
    var end = str.startIndex
    while end < str.endIndex && str[end].isNumber {
        end = str.index(after: end)
    }
    guard end > str.startIndex else { return nil }
    return Int(str[str.startIndex ..< end])
}
