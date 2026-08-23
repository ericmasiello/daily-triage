import Foundation

// MARK: - Cross-service analysis

// Blends GitLab's MR/worktree data with Jira's issue data into one ANALYSIS block and one
// recommendation string. Neither GitLabService nor JiraService knows about the other —
// this is the one place that does, per the architecture call made for the Jira migration.

struct AnalysisResult: Codable {
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

struct Tier1MR: Codable {
    let iid: Int
    let title: String
    let reviewStatus: String
    let ageHours: Int
    let webUrl: String?
}

struct ReviewQueueMR: Codable {
    let iid: Int
    let title: String
    let repo: String
    let role: String
    let ageHours: Int
    let webUrl: String?
}

struct StaleWorktree: Codable {
    let path: String
    let reason: String
}

/// A Jira work item classified into tier_2 (near-complete workstream) or tier_3 (everything
/// else). Uses `key` (Jira's string identifier, e.g. "ERICRULEZ-42") rather than an integer
/// `iid` — GitLab's old TierIssue used `iid` because GitLab issues are integer-keyed.
struct TierIssue: Codable {
    let key: String
    let title: String
    let workstreamCompletion: Int?
    let priority: String?
    let reason: String
    let webUrl: String?
}

struct PRDHierarchyEntry: Codable {
    let parentKey: String
    let title: String
    let children: [ChildInfo]
    let completion: CompletionInfo

    enum CodingKeys: String, CodingKey {
        case parentKey = "parent_key"
        case title, children, completion
    }
}

struct ChildInfo: Codable {
    let key: String
    let status: String
}

struct CompletionInfo: Codable {
    let closed: Int
    let total: Int
    let percentage: Int
}

// MARK: - Entry point

func computeAnalysis(snapshot: Snapshot, todayDate: String) -> AnalysisResult {
    let referenceDate = parseReferenceDate(todayDate)
    let allJiraIssues = snapshot.jira?.allIssues ?? []
    let openJiraIssues = snapshot.jira?.openIssues ?? []

    let entries = buildPRDHierarchy(allIssues: allJiraIssues)
    let tiers = computeIssueTiers(openIssues: openJiraIssues, entries: entries)
    let tier2 = tiers.tier2
    let tier3 = tiers.tier3
    let parentByKey = tiers.parentByKey

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
        parentByKey: parentByKey,
        allIssuesByKey: Dictionary(allJiraIssues.map { ($0.key, $0) }) { _, latest in latest }
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

/// The ANALYSIS block's text-output lines, emitted once from App.swift.
func formatAnalysis(_ analysis: AnalysisResult) -> [String] {
    var lines = ["---ANALYSIS---"]
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    if let data = try? encoder.encode(analysis), let str = String(data: data, encoding: .utf8) {
        lines.append(str)
    }
    lines.append("---END_ANALYSIS---")
    return lines
}

private func parseReferenceDate(_ todayDate: String) -> Date {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd"
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter.date(from: todayDate) ?? Date()
}

// MARK: - Jira PRD hierarchy

private func buildPRDHierarchy(allIssues: [JiraIssue]) -> [PRDHierarchyEntry] {
    let issuesByKey = Dictionary(allIssues.map { ($0.key, $0) }) { _, latest in latest }

    var parentToChildren: [String: [JiraIssue]] = [:]
    for issue in allIssues {
        guard let parentKey = issue.parentKey else { continue }
        parentToChildren[parentKey, default: []].append(issue)
    }

    return parentToChildren.keys.sorted().map { parentKey in
        let children = parentToChildren[parentKey]!.sorted { $0.key < $1.key }
        // Parent-type issues always come from the same `project = X` fetch as their
        // children (JiraService only resolves `parent = <key>` for issues found in that
        // same fetch), so this should always resolve — the fallback is defensive only.
        let title = issuesByKey[parentKey]?.summary ?? "Unknown issue \(parentKey)"
        let childInfos = children.map { ChildInfo(key: $0.key, status: $0.status) }
        let closedCount = children.filter { isJiraIssueDone($0.status) }.count
        let total = children.count
        let percentage = total > 0 ? (closedCount * 100) / total : 0
        return PRDHierarchyEntry(
            parentKey: parentKey,
            title: title,
            children: childInfos,
            completion: CompletionInfo(closed: closedCount, total: total, percentage: percentage)
        )
    }
}

private struct IssueTierResult {
    var tier2: [TierIssue]
    var tier3: [TierIssue]
    var parentByKey: [String: String]
}

private func computeIssueTiers(
    openIssues: [JiraIssue],
    entries: [PRDHierarchyEntry]
) -> IssueTierResult {
    var childToCompletion: [String: Int] = [:]
    var parentByKey: [String: String] = [:]
    for entry in entries {
        for child in entry.children {
            let existing = childToCompletion[child.key] ?? -1
            if entry.completion.percentage > existing {
                childToCompletion[child.key] = entry.completion.percentage
                parentByKey[child.key] = entry.parentKey
            }
        }
    }

    let parentKeys = Set(entries.map(\.parentKey))
    var tier2: [TierIssue] = []
    var tier3: [TierIssue] = []

    for issue in openIssues where !parentKeys.contains(issue.key) {
        if let completion = childToCompletion[issue.key], completion >= 80 {
            tier2.append(TierIssue(
                key: issue.key,
                title: issue.summary,
                workstreamCompletion: completion,
                priority: issue.priority,
                reason: "near_complete_workstream",
                webUrl: issue.webUrl
            ))
        } else {
            tier3.append(TierIssue(
                key: issue.key,
                title: issue.summary,
                workstreamCompletion: nil,
                priority: issue.priority,
                reason: "remaining_by_value_age",
                webUrl: issue.webUrl
            ))
        }
    }

    let sortByPriority = { (lhs: TierIssue, rhs: TierIssue) -> Bool in
        let rankLhs = jiraPriorityRank(lhs.priority)
        let rankRhs = jiraPriorityRank(rhs.priority)
        return rankLhs != rankRhs ? rankLhs < rankRhs : lhs.key < rhs.key
    }
    tier2.sort(by: sortByPriority)
    tier3.sort(by: sortByPriority)

    return IssueTierResult(tier2: tier2, tier3: tier3, parentByKey: parentByKey)
}

private func jiraPriorityRank(_ priority: String?) -> Int {
    switch priority?.lowercased() {
    case "highest": 0
    case "high": 1
    case "medium": 2
    case "low": 3
    case "lowest": 4
    default: 5
    }
}

// MARK: - GitLab MR ranking (unchanged behavior, moved from GitLabService)

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

// MARK: - Recommendation

private func computeRecommendationString(
    tier1: [Tier1MR],
    tier2: [TierIssue],
    tier3: [TierIssue],
    parentByKey: [String: String],
    allIssuesByKey: [String: JiraIssue]
) -> String {
    if let mr = tier1.first(where: { $0.reviewStatus == "changes_requested" }) {
        return "Address review feedback on MR !\(mr.iid)"
    }
    if let mr = tier1.first(where: { $0.reviewStatus == "awaiting_review" }) {
        return "Follow up on MR !\(mr.iid) review"
    }
    if let issue = tier2.first {
        let prdTitle: String = if let parentKey = parentByKey[issue.key],
                                  let parent = allIssuesByKey[parentKey] {
            parent.summary
        } else {
            "work stream"
        }
        let pct = issue.workstreamCompletion ?? 0
        return "Complete near-done work stream: \(prdTitle) (\(pct)%)"
    }
    if let issue = tier3.first {
        return "Work on \(issue.key): \(issue.title)"
    }
    return "No actionable items"
}
