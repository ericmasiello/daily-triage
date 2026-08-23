import Foundation

// MARK: - Jira value types

/// A Jira work item with the fields relevant for triage.
/// Jira keys are strings (e.g. "ERICRULEZ-42"), unlike GitLab's integer `iid`.
struct JiraIssue: Codable, Equatable {
    let key: String
    let summary: String
    let status: String
    let priority: String?
    let issueType: String?
    /// Key of the parent work item (e.g. a Workstream), if any. `acli`'s `search --fields`
    /// doesn't allow requesting `parent` directly (see JiraService.fetch) — this is filled
    /// in afterward from a separate `parent = <key>` JQL lookup per parent-type issue, so
    /// it's always resolvable against this same fetch's `allIssues` by key.
    let parentKey: String?
    let webUrl: String
}

// MARK: - Jira Service

struct JiraService: DataSourceService {
    let label = "jira"
    let failurePolicy: FailurePolicy = .degradable

    struct State: Codable, Equatable {
        /// Every work item returned for the project — needed to build the parent/child
        /// hierarchy and completion percentages, mirroring GitLab's old `allIssues`.
        var allIssues: [JiraIssue]
        /// Non-done work items — what gets tiered into tier_2/tier_3 in Analysis.swift.
        var openIssues: [JiraIssue]
    }

    private(set) var fetchedState: State?
    private(set) var fetchError: String?

    // MARK: - Protocol: fetch

    mutating func fetch(config: Config, shell: @escaping ShellRunner) async throws {
        // Scoped by project only (no assignee filter), mirroring GitLab's old
        // `fetchIssues` semantics: the PRD-hierarchy/completion math needs full
        // visibility into every work item in the project, not just the ones
        // assigned to the current user.
        //
        // `acli jira workitem search --fields` only allows a small set of simple fields
        // (key, summary, status, priority, issuetype, assignee, labels, description,
        // reporter) — relational fields like `parent`, `created`, and `updated` are
        // rejected outright ("field 'parent' is not allowed"), even though `acli`'s own
        // docs/examples suggest otherwise. Parent info instead comes from a second pass:
        // for every issue whose type looks like a workstream/epic, run a `parent = <key>`
        // JQL search to find its children (see fetchParentAssignments below).
        //
        // Caught internally (not rethrown), matching TodoistService's convention: failure
        // is signaled via `fetchError`, which `reconcileIfNeeded` inspects — not via `throws`.
        let jql = "project = \(config.jiraProject)"
        let fields = "key,summary,status,priority,issuetype"
        let command = "acli jira workitem search --jql \"\(jql)\" --fields \"\(fields)\" --paginate --json"
        do {
            let out = try shell(command, nil)
            let baseIssues = decodeJiraIssues(out, site: config.jiraSite)
            let parentKeys = baseIssues.filter { isParentIssueType($0.issueType) }.map(\.key)
            let parentByChildKey = await fetchParentAssignments(parentKeys: parentKeys, shell: shell)
            let issues = baseIssues.map { $0.withParentKey(parentByChildKey[$0.key]) }
            fetchedState = State(allIssues: issues, openIssues: issues.filter { !isJiraIssueDone($0.status) })
            fetchError = nil
        } catch {
            fetchedState = nil
            fetchError = "\(error)"
        }
    }

    // MARK: - Protocol: diff

    func diff(cached: Snapshot, fresh: Snapshot) -> (changes: [String], signals: [DiffSignal]) {
        let (changes, hasPriorityChange) = diffJiraIssues(cached: cached.jira, fresh: fresh.jira)
        return (changes, hasPriorityChange ? [.priorityChange] : [])
    }

    // MARK: - Protocol: format

    /// Analysis (tier_2/tier_3 issues, PRD hierarchy, recommendation) is a cross-service
    /// concern that blends this data with GitLab's MR data — it lives in Analysis.swift
    /// and is emitted once from App.swift, not per-service. See Analysis.swift.
    func format(_: Snapshot) -> [String] {
        []
    }

    // MARK: - Reconciliation

    /// Falls back to cached Jira state after a fetch failure.
    /// Returns `true` if cached state existed and was restored (safe to continue).
    /// Returns `false` if there is nothing to fall back to — the caller must treat
    /// this as fatal rather than silently producing a recommendation with no Jira
    /// data behind it.
    @discardableResult
    mutating func reconcileIfNeeded(cached: Snapshot?) -> Bool {
        guard let err = fetchError else { return true }
        guard let cachedJira = cached?.jira else {
            return false
        }
        fputs("Warning: Jira fetch failed (\(err)), using cached data\n", stderr)
        fetchedState = cachedJira
        fetchError = nil
        return true
    }
}

// MARK: - Done-status heuristic

/// Jira workflows are configurable, so there's no fixed "closed" literal like GitLab's
/// `state == "closed"`. This is a pragmatic heuristic: treat any status whose name
/// contains one of these words as done-equivalent. Teams with unusual workflow status
/// names (e.g. "Shipped") won't be recognized — acceptable for a personal triage tool,
/// but worth revisiting if it ever misclassifies your board's actual terminal statuses.
private let doneStatusKeywords = ["done", "closed", "resolved", "complete", "cancelled", "canceled"]

func isJiraIssueDone(_ status: String) -> Bool {
    let lower = status.lowercased()
    return doneStatusKeywords.contains { lower.contains($0) }
}

// MARK: - Parent/child resolution

/// Issue types treated as hierarchy roots (GitLab's old "PRD" concept). "Workstream" is
/// this board's actual custom issue type (see the studio-migrate-to-jira skill); "Epic" is
/// included too since that's Jira's standard parent type on boards that don't customize it.
private let parentIssueTypes: Set<String> = ["workstream", "epic"]

private func isParentIssueType(_ issueType: String?) -> Bool {
    guard let issueType else { return false }
    return parentIssueTypes.contains(issueType.lowercased())
}

/// For each parent-type issue key, runs `parent = <key>` and returns a childKey → parentKey
/// map. One call per parent (not per issue) — `acli` has no bulk "give me every issue's
/// parent" query, so this is the cheapest way to reconstruct the hierarchy.
private func fetchParentAssignments(
    parentKeys: [String],
    shell: @escaping ShellRunner
) async -> [String: String] {
    guard !parentKeys.isEmpty else { return [:] }

    return await withTaskGroup(of: [String: String].self) { group in
        for parentKey in parentKeys {
            group.addTask {
                do {
                    let command = "acli jira workitem search --jql \"parent = \(parentKey)\" --paginate --json"
                    let out = try shell(command, nil)
                    let childKeys = decodeJiraKeys(out)
                    return Dictionary(childKeys.map { ($0, parentKey) }) { _, latest in latest }
                } catch {
                    fputs("Warning: failed to fetch children of \(parentKey) — \(error)\n", stderr)
                    return [:]
                }
            }
        }

        var merged: [String: String] = [:]
        for await partial in group {
            merged.merge(partial) { _, new in new }
        }
        return merged
    }
}

// MARK: - Raw acli JSON shapes (file-private)

private struct RawJiraSearchItem: Decodable {
    let key: String
    let fields: RawJiraFields
}

private struct RawJiraFields: Decodable {
    let summary: String
    let status: RawJiraNamed?
    let priority: RawJiraNamed?
    let issuetype: RawJiraNamed?
}

private struct RawJiraNamed: Decodable {
    let name: String
}

/// Response shape for the `parent = <key>` children lookup — only `key` is used, so no
/// `--fields` is requested for that query and the rest of the payload is ignored.
private struct RawJiraKeyOnly: Decodable {
    let key: String
}

// MARK: - Raw → Typed mapping

private extension JiraIssue {
    init(from raw: RawJiraSearchItem, site: String) {
        self.init(
            key: raw.key,
            summary: raw.fields.summary,
            status: raw.fields.status?.name ?? "Unknown",
            priority: raw.fields.priority?.name,
            issueType: raw.fields.issuetype?.name,
            parentKey: nil,
            webUrl: "\(site)/browse/\(raw.key)"
        )
    }

    func withParentKey(_ parentKey: String?) -> JiraIssue {
        JiraIssue(
            key: key,
            summary: summary,
            status: status,
            priority: priority,
            issueType: issueType,
            parentKey: parentKey,
            webUrl: webUrl
        )
    }
}

// MARK: - JSON decoding

private func decodeJiraIssues(_ string: String, site: String) -> [JiraIssue] {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    guard let raw = try? decoder.decode([RawJiraSearchItem].self, from: data) else { return [] }
    return raw.map { JiraIssue(from: $0, site: site) }
}

private func decodeJiraKeys(_ string: String) -> [String] {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    guard let raw = try? decoder.decode([RawJiraKeyOnly].self, from: data) else { return [] }
    return raw.map(\.key)
}

// MARK: - Diff internals

private func diffJiraIssues(
    cached: JiraService.State?,
    fresh: JiraService.State?
) -> (changes: [String], hasPriorityChange: Bool) {
    if cached == nil && fresh == nil {
        return ([], false)
    }

    let cachedIssues = cached?.allIssues ?? []
    let freshIssues = fresh?.allIssues ?? []

    let cachedByKey = Dictionary(cachedIssues.map { ($0.key, $0) }) { _, latest in latest }
    let freshByKey = Dictionary(freshIssues.map { ($0.key, $0) }) { _, latest in latest }

    let cachedKeys = Set(cachedByKey.keys)
    let freshKeys = Set(freshByKey.keys)

    var changes: [String] = []
    var hasPriorityChange = false

    for key in freshKeys.subtracting(cachedKeys).sorted() {
        changes.append("Jira \(key): added (\(freshByKey[key]!.summary))")
    }

    for key in cachedKeys.subtracting(freshKeys).sorted() {
        changes.append("Jira \(key): removed (\(cachedByKey[key]!.summary))")
    }

    for key in cachedKeys.intersection(freshKeys).sorted() {
        let old = cachedByKey[key]!
        let new = freshByKey[key]!

        if old.status != new.status {
            changes.append("Jira \(key): status changed \(old.status) → \(new.status)")
            if isJiraIssueDone(old.status) != isJiraIssueDone(new.status) {
                hasPriorityChange = true
            }
        }
        if old.priority != new.priority {
            let from = old.priority ?? "none"
            let to = new.priority ?? "none"
            changes.append("Jira \(key): priority changed \(from) → \(to)")
            hasPriorityChange = true
        }
    }

    return (changes, hasPriorityChange)
}
