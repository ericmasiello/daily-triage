import Foundation

/// A merge request with the fields relevant for triage.
struct MR: Codable, Equatable {
    let iid: Int
    let title: String
    let draft: Bool?
    let sourceBranch: String?
    let createdAt: String?
    let updatedAt: String?
    let webUrl: String?
    let labels: [String]
    let detailedMergeStatus: String?
    let userNotesCount: Int?
    let hasConflicts: Bool?
    let reviewerUsernames: [String]?
    /// Full repo path, e.g. "vistaprint-org/design-technology/studio/studio".
    /// Populated for cross-repo MRs fetched via the instance-level API.
    let repoPath: String?
}

struct Snapshot: Codable {
    var nonDraftMrs: [MR]
    var draftMrs: [MR]
    var sandcastleMrs: [MR]
    var reviewerMrs: [MR]
    var assignedMrs: [MR]
    var worktrees: [String]
    var mergedBranches: [String]
    var todoist: TodoistService.State?
    var todoistError: String?
    var jira: JiraService.State?
    var jiraError: String?

    var gitlab: GitLabService.State {
        get {
            GitLabService.State(
                nonDraftMrs: nonDraftMrs,
                draftMrs: draftMrs,
                sandcastleMrs: sandcastleMrs,
                reviewerMrs: reviewerMrs,
                assignedMrs: assignedMrs,
                worktrees: worktrees,
                mergedBranches: mergedBranches
            )
        }
        set {
            nonDraftMrs = newValue.nonDraftMrs
            draftMrs = newValue.draftMrs
            sandcastleMrs = newValue.sandcastleMrs
            reviewerMrs = newValue.reviewerMrs
            assignedMrs = newValue.assignedMrs
            worktrees = newValue.worktrees
            mergedBranches = newValue.mergedBranches
        }
    }

    init(
        gitlab: GitLabService.State,
        todoist: TodoistService.State?,
        todoistError: String?,
        jira: JiraService.State?,
        jiraError: String?
    ) {
        nonDraftMrs = gitlab.nonDraftMrs
        draftMrs = gitlab.draftMrs
        sandcastleMrs = gitlab.sandcastleMrs
        reviewerMrs = gitlab.reviewerMrs
        assignedMrs = gitlab.assignedMrs
        worktrees = gitlab.worktrees
        mergedBranches = gitlab.mergedBranches
        self.todoist = todoist
        self.todoistError = todoistError
        self.jira = jira
        self.jiraError = jiraError
    }

    init(
        nonDraftMrs: [MR],
        draftMrs: [MR],
        sandcastleMrs: [MR],
        reviewerMrs: [MR] = [],
        assignedMrs: [MR] = [],
        worktrees: [String],
        mergedBranches: [String],
        todoist: TodoistService.State? = nil,
        todoistError: String? = nil,
        jira: JiraService.State? = nil,
        jiraError: String? = nil
    ) {
        self.nonDraftMrs = nonDraftMrs
        self.draftMrs = draftMrs
        self.sandcastleMrs = sandcastleMrs
        self.reviewerMrs = reviewerMrs
        self.assignedMrs = assignedMrs
        self.worktrees = worktrees
        self.mergedBranches = mergedBranches
        self.todoist = todoist
        self.todoistError = todoistError
        self.jira = jira
        self.jiraError = jiraError
    }
}

/// The on-disk cache envelope (v2 schema).
struct CacheEnvelope: Codable {
    let version: Int
    let timestamp: String
    let ttlSeconds: Int
    let snapshot: Snapshot
    var report: String?
    var recommendation: String?
}
