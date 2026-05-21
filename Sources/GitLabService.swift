import Foundation

// MARK: - GitLab Service

struct GitLabService: DataSourceService {
    let label = "gitlab"
    let failurePolicy: FailurePolicy = .fatal

    struct State: Codable, Equatable {
        var nonDraftMrs: [MR]
        var draftMrs: [MR]
        var sandcastleMrs: [MR]
        var issues: [Issue]
        var worktrees: [String]
        var mergedBranches: [String]
    }

    private(set) var fetchedState: State?
    private(set) var issueDescriptions: [Int: String] = [:]
    private(set) var allIssues: [Issue] = []

    // MARK: - Protocol: fetch

    mutating func fetch(config: Config, shell: @escaping ShellRunner) async throws {
        let outputs = await fetchAllGitLab(config: config, shell: shell)

        var nonDraftMRs:   [MR] = []
        var draftMRs:      [MR] = []
        var sandcastleMRs: [MR] = []
        var issuesList:    [Issue] = []
        var allIssuesList: [Issue] = []
        var descriptions:  [Int: String] = [:]
        var worktreesList: [String] = []
        var mergedBranchesList: [String] = []
        var errors: [String] = []

        for output in outputs {
            switch output {
            case .nonDraftMRs(let mrs):   nonDraftMRs = mrs
            case .draftMRs(let mrs):      draftMRs = mrs
            case .sandcastleMRs(let mrs): sandcastleMRs = mrs
            case .issues(let open, let descs, let all):
                issuesList = open
                descriptions = descs
                allIssuesList = all
            case .worktrees(let dirs):    worktreesList = dirs
            case .mergedBranches(let b):  mergedBranchesList = b
            case .failed(let desc):       errors.append(desc)
            }
        }

        if errors.count >= 4 {
            throw GitLabFetchError.tooManyFailures(errors)
        }

        let worktreeSet = Set(worktreesList)
        let filteredBranches = mergedBranchesList.filter { branch in
            let name = branch
                .split(separator: "/", maxSplits: 1)
                .last
                .map(String.init) ?? branch
            return worktreeSet.contains(name)
        }

        fetchedState = State(
            nonDraftMrs: nonDraftMRs,
            draftMrs: draftMRs,
            sandcastleMrs: sandcastleMRs,
            issues: issuesList,
            worktrees: worktreesList,
            mergedBranches: filteredBranches
        )
        issueDescriptions = descriptions
        allIssues = allIssuesList
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
        diffIssues(&changes, hasPriorityChange: &hasPriorityChange,
                   cached: old.issues, fresh: new.issues)
        diffStringSet(&changes, label: "Worktree", cached: old.worktrees, fresh: new.worktrees)
        diffStringSet(&changes, label: "Merged branch", cached: old.mergedBranches, fresh: new.mergedBranches)

        var signals: [DiffSignal] = []
        if hasPriorityChange { signals.append(.priorityChange) }

        return (changes, signals)
    }

    // MARK: - Protocol: format

    func format(_ snapshot: Snapshot) -> [String] {
        let analysis = computeAnalysis(
            snapshot: snapshot,
            issueDescriptions: issueDescriptions,
            allIssues: allIssues
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
}

// MARK: - Fetch Error

enum GitLabFetchError: Error, CustomStringConvertible {
    case tooManyFailures([String])

    var description: String {
        switch self {
        case .tooManyFailures(let errors):
            return "all GitLab data sources failed: \(errors.joined(separator: ", "))"
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

// MARK: - Raw → Typed mapping

private func mapRawMR(_ raw: RawMR) -> MR {
    MR(
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

private func fetchAllGitLab(config: Config, shell: @escaping ShellRunner) async -> [FetchOutput] {
    await withTaskGroup(of: FetchOutput.self) { group in
        group.addTask {
            fetchSource("glab mr list --author=\(config.triageAuthor) --not-draft -F json --per-page 50",
                        dir: config.studioDir, label: "non-draft MRs", runShell: shell) { out in
                .nonDraftMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            fetchSource("glab mr list --author=\(config.triageAuthor) --draft -F json --per-page 50",
                        dir: config.studioDir, label: "draft MRs", runShell: shell) { out in
                .draftMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            fetchSource("glab mr list --author=\(config.triageAuthor) -F json --per-page 50 --repo ericmasiello/sandcastle-studio",
                        dir: config.studioDir, label: "sandcastle MRs", runShell: shell) { out in
                .sandcastleMRs((decodeArray(out) as [RawMR]).map { mapRawMR($0) })
            }
        }

        group.addTask {
            do {
                let out = try shell("glab issue list -O json --per-page 100 --all", config.studioDir)
                let rawIssues: [RawIssue] = decodeArray(out)
                let all = rawIssues.map { mapRawIssue($0) }
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

        group.addTask {
            let worktreePath = (config.studioDir as NSString).appendingPathComponent(".worktrees")
            let out = (try? shell("ls '\(worktreePath)' 2>/dev/null", nil)) ?? ""
            let dirs = out.components(separatedBy: "\n").filter { !$0.isEmpty }
            return .worktrees(dirs)
        }

        group.addTask {
            let rawDefault = (try? shell(
                "git -C '\(config.studioDir)' symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'", nil)) ?? ""
            let defaultBranch = rawDefault.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = defaultBranch.isEmpty ? "master" : defaultBranch

            let branchOut = (try? shell("git -C '\(config.studioDir)' branch -r --merged '\(branch)' 2>/dev/null", nil)) ?? ""
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
    let cachedByIID = Dictionary(cached.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })
    let freshByIID = Dictionary(fresh.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })

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
            changes.append(
                "\(label) !\(iid): detailed_merge_status changed \(old.detailedMergeStatus ?? "null") → \(new.detailedMergeStatus ?? "null")")
        }
        if old.hasConflicts != new.hasConflicts {
            changes.append(
                "\(label) !\(iid): has_conflicts changed \(describeOptional(old.hasConflicts)) → \(describeOptional(new.hasConflicts))")
        }
        if old.userNotesCount != new.userNotesCount {
            changes.append(
                "\(label) !\(iid): user_notes_count changed \(describeOptional(old.userNotesCount)) → \(describeOptional(new.userNotesCount))")
        }
        if old.labels != new.labels {
            changes.append(
                "\(label) !\(iid): labels changed [\(old.labels.joined(separator: ", "))] → [\(new.labels.joined(separator: ", "))]")
        }
    }
}

private func diffIssues(_ changes: inout [String], hasPriorityChange: inout Bool,
                        cached: [Issue], fresh: [Issue]) {
    let cachedByIID = Dictionary(cached.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })
    let freshByIID = Dictionary(fresh.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })

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
            if !added.isEmpty { parts.append("added \(added.sorted().joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("removed \(removed.sorted().joined(separator: ", "))") }
            changes.append("Issue #\(iid): labels \(parts.joined(separator: "; "))")
        }
    }

    for iid in freshIIDs.subtracting(cachedIIDs) {
        if freshByIID[iid]!.labels.contains(where: { $0.hasPrefix("p::") }) {
            hasPriorityChange = true
        }
    }
    for iid in cachedIIDs.subtracting(freshIIDs) {
        if cachedByIID[iid]!.labels.contains(where: { $0.hasPrefix("p::") }) {
            hasPriorityChange = true
        }
    }
}

private func diffStringSet(_ changes: inout [String], label: String,
                            cached: [String], fresh: [String]) {
    let cachedSet = Set(cached)
    let freshSet = Set(fresh)

    for item in freshSet.subtracting(cachedSet).sorted() {
        changes.append("\(label): added \(item)")
    }
    for item in cachedSet.subtracting(freshSet).sorted() {
        changes.append("\(label): removed \(item)")
    }
}

private func describeOptional<T>(_ value: T?) -> String {
    guard let value = value else { return "null" }
    return "\(value)"
}

// MARK: - Analysis internals

private struct AnalysisResult: Codable {
    let prdHierarchy: [PRDHierarchyEntry]
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

private func computeAnalysis(snapshot: Snapshot, issueDescriptions: [Int: String], allIssues: [Issue]) -> AnalysisResult {
    let issuesByIID = Dictionary(
        allIssues.map { ($0.iid, $0) },
        uniquingKeysWith: { _, b in b }
    )

    var parentToChildren: [Int: [Int]] = [:]

    for (iid, description) in issueDescriptions {
        for parentIID in parseParentReferences(description) {
            parentToChildren[parentIID, default: []].append(iid)
        }
    }

    var entries: [PRDHierarchyEntry] = []

    for prdIID in parentToChildren.keys.sorted() {
        let childIIDs = parentToChildren[prdIID]!.sorted()
        let title = issuesByIID[prdIID]?.title ?? "Unknown issue #\(prdIID)"

        let children: [ChildInfo] = childIIDs.map { childIID in
            let state: String
            if let issue = issuesByIID[childIID] {
                state = issue.state ?? "opened"
            } else {
                state = "closed"
            }
            return ChildInfo(iid: childIID, state: state)
        }

        let closedCount = children.filter { $0.state == "closed" }.count
        let total = children.count
        let percentage = total > 0 ? (closedCount * 100) / total : 0

        entries.append(PRDHierarchyEntry(
            prdIid: prdIID,
            title: title,
            children: children,
            completion: CompletionInfo(closed: closedCount, total: total, percentage: percentage)
        ))
    }

    return AnalysisResult(prdHierarchy: entries)
}

// MARK: - Description parsing

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
                if end > afterHash, let iid = Int(text[afterHash..<end]) {
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

private func parseLeadingInt(_ s: String) -> Int? {
    var end = s.startIndex
    while end < s.endIndex && s[end].isNumber {
        end = s.index(after: end)
    }
    guard end > s.startIndex else { return nil }
    return Int(s[s.startIndex..<end])
}
