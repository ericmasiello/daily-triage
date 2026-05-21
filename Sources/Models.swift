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

/// A due date on a Todoist task.
struct TodoistDue: Codable, Equatable {
    let date: String
    let isRecurring: Bool
    let string: String?
}

/// A Todoist task with the fields relevant for triage.
struct TodoistTask: Codable, Equatable {
    let id: String
    let content: String
    let priority: Int
    let due: TodoistDue?
    let labels: [String]
    let url: String
}

/// Todoist tasks grouped by urgency.
struct TodoistSnapshot: Codable, Equatable {
    let overdue: [TodoistTask]
    let today: [TodoistTask]
    let upNext: [TodoistTask]
}

/// A complete snapshot of all triage data sources.
struct Snapshot: Codable {
    var nonDraftMrs: [MR]
    var draftMrs: [MR]
    var sandcastleMrs: [MR]
    var issues: [Issue]
    var worktrees: [String]
    var mergedBranches: [String]
    var todoist: TodoistSnapshot?
    var todoistError: String?

    /// Adapter: read/write the GitLab slice without changing encoded JSON shape.
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

    /// Build a Snapshot from a GitLabService.State plus Todoist fields.
    init(gitlab: GitLabService.State, todoist: TodoistSnapshot?, todoistError: String?) {
        self.nonDraftMrs = gitlab.nonDraftMrs
        self.draftMrs = gitlab.draftMrs
        self.sandcastleMrs = gitlab.sandcastleMrs
        self.issues = gitlab.issues
        self.worktrees = gitlab.worktrees
        self.mergedBranches = gitlab.mergedBranches
        self.todoist = todoist
        self.todoistError = todoistError
    }

    /// Memberwise init (preserves existing call sites).
    init(nonDraftMrs: [MR], draftMrs: [MR], sandcastleMrs: [MR], issues: [Issue],
         worktrees: [String], mergedBranches: [String],
         todoist: TodoistSnapshot? = nil, todoistError: String? = nil) {
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
