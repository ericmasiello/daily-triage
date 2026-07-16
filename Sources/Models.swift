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

/// An issue with the fields relevant for triage.
struct Issue: Codable, Equatable {
    let iid: Int
    let title: String
    let state: String?
    let labels: [String]
    let createdAt: String?
    let webUrl: String?
}

struct Snapshot: Codable {
    var nonDraftMrs: [MR]
    var draftMrs: [MR]
    var sandcastleMrs: [MR]
    var reviewerMrs: [MR]
    var assignedMrs: [MR]
    var issues: [Issue]
    var worktrees: [String]
    var mergedBranches: [String]
    var todoist: TodoistService.State?
    var todoistError: String?

    var gitlab: GitLabService.State {
        get {
            GitLabService.State(
                nonDraftMrs: nonDraftMrs,
                draftMrs: draftMrs,
                sandcastleMrs: sandcastleMrs,
                reviewerMrs: reviewerMrs,
                assignedMrs: assignedMrs,
                issues: issues,
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
            issues = newValue.issues
            worktrees = newValue.worktrees
            mergedBranches = newValue.mergedBranches
        }
    }

    init(gitlab: GitLabService.State, todoist: TodoistService.State?, todoistError: String?) {
        self.nonDraftMrs = gitlab.nonDraftMrs
        self.draftMrs = gitlab.draftMrs
        self.sandcastleMrs = gitlab.sandcastleMrs
        self.reviewerMrs = gitlab.reviewerMrs
        self.assignedMrs = gitlab.assignedMrs
        self.issues = gitlab.issues
        self.worktrees = gitlab.worktrees
        self.mergedBranches = gitlab.mergedBranches
        self.todoist = todoist
        self.todoistError = todoistError
    }

    init(
        nonDraftMrs: [MR],
        draftMrs: [MR],
        sandcastleMrs: [MR],
        reviewerMrs: [MR] = [],
        assignedMrs: [MR] = [],
        issues: [Issue],
        worktrees: [String],
        mergedBranches: [String],
        todoist: TodoistService.State? = nil,
        todoistError: String? = nil
    ) {
        self.nonDraftMrs = nonDraftMrs
        self.draftMrs = draftMrs
        self.sandcastleMrs = sandcastleMrs
        self.reviewerMrs = reviewerMrs
        self.assignedMrs = assignedMrs
        self.issues = issues
        self.worktrees = worktrees
        self.mergedBranches = mergedBranches
        self.todoist = todoist
        self.todoistError = todoistError
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
