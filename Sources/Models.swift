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
                issues: issues,
                worktrees: worktrees,
                mergedBranches: mergedBranches
            )
        }
        set {
            nonDraftMrs = newValue.nonDraftMrs
            draftMrs = newValue.draftMrs
            sandcastleMrs = newValue.sandcastleMrs
            issues = newValue.issues
            worktrees = newValue.worktrees
            mergedBranches = newValue.mergedBranches
        }
    }

    init(gitlab: GitLabService.State, todoist: TodoistService.State?, todoistError: String?) {
        nonDraftMrs = gitlab.nonDraftMrs
        draftMrs = gitlab.draftMrs
        sandcastleMrs = gitlab.sandcastleMrs
        issues = gitlab.issues
        worktrees = gitlab.worktrees
        mergedBranches = gitlab.mergedBranches
        self.todoist = todoist
        self.todoistError = todoistError
    }

    init(
        nonDraftMrs: [MR],
        draftMrs: [MR],
        sandcastleMrs: [MR],
        issues: [Issue],
        worktrees: [String],
        mergedBranches: [String],
        todoist: TodoistService.State? = nil,
        todoistError: String? = nil
    ) {
        self.nonDraftMrs = nonDraftMrs
        self.draftMrs = draftMrs
        self.sandcastleMrs = sandcastleMrs
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
