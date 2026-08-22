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
    /// Key of the parent work item (e.g. an Epic), if any.
    let parentKey: String?
    /// Summary of the parent, when the search response included nested parent fields.
    /// Used as a hierarchy-title fallback when the parent itself wasn't independently
    /// returned by the search (e.g. it belongs to a different project).
    let parentSummary: String?
    let createdAt: String?
    let updatedAt: String?
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
        let jql = "project = \(config.jiraProject)"
        let fields = "key,summary,status,priority,issuetype,parent,created,updated"
        let command = "acli jira workitem search --jql \"\(jql)\" --fields \"\(fields)\" --paginate --json"
        // Caught internally (not rethrown), matching TodoistService's convention: failure
        // is signaled via `fetchError`, which `reconcileIfNeeded` inspects — not via `throws`.
        do {
            let out = try shell(command, nil)
            let issues = decodeJiraIssues(out, site: config.jiraSite)
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
    let parent: RawJiraParent?
    let created: String?
    let updated: String?
}

private struct RawJiraNamed: Decodable {
    let name: String
}

private struct RawJiraParent: Decodable {
    let key: String
    let fields: RawJiraParentFields?
}

private struct RawJiraParentFields: Decodable {
    let summary: String?
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
            parentKey: raw.fields.parent?.key,
            parentSummary: raw.fields.parent?.fields?.summary,
            createdAt: raw.fields.created,
            updatedAt: raw.fields.updated,
            webUrl: "\(site)/browse/\(raw.key)"
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
