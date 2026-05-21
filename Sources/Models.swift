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
    let nonDraftMrs: [MR]
    let draftMrs: [MR]
    let sandcastleMrs: [MR]
    let issues: [Issue]
    let worktrees: [String]
    let mergedBranches: [String]
    var todoist: TodoistSnapshot?
    var todoistError: String?
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
