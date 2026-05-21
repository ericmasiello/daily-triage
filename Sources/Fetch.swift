import Foundation

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

// MARK: - Raw → Typed mapping (file-private)

private extension MR {
    init(from raw: RawMR) {
        self.init(
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
}

private extension Issue {
    init(from raw: RawIssue) {
        self.init(
            iid: raw.iid,
            title: raw.title,
            state: raw.state,
            labels: raw.labels ?? [],
            createdAt: raw.createdAt,
            webUrl: raw.webUrl
        )
    }
}

// MARK: - Raw Todoist JSON shapes (file-private)

private struct RawTodoistResponse: Decodable {
    let results: [RawTodoistTask]
}

private struct RawTodoistTask: Decodable {
    let id: String
    let content: String
    let priority: Int
    let due: RawTodoistDue?
    let labels: [String]
    let url: String
}

private struct RawTodoistDue: Decodable {
    let date: String
    let isRecurring: Bool
    let string: String?
}

private extension TodoistTask {
    init(from raw: RawTodoistTask) {
        self.init(
            id: raw.id,
            content: raw.content,
            priority: raw.priority,
            due: raw.due.map { TodoistDue(date: $0.date, isRecurring: $0.isRecurring, string: $0.string) },
            labels: raw.labels,
            url: raw.url
        )
    }
}

// MARK: - JSON decoding helpers

private func decodeArray<T: Decodable>(_ string: String) -> [T] {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return (try? decoder.decode([T].self, from: data)) ?? []
}

private func decodeTodoistTasks(_ string: String) -> [TodoistTask] {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    guard let response = try? decoder.decode(RawTodoistResponse.self, from: data) else { return [] }
    return response.results.map { TodoistTask(from: $0) }
}

// MARK: - Public fetch

enum FetchResult {
    case success(snapshot: Snapshot, issueDescriptions: [Int: String], allIssues: [Issue])
    case failure([String])
}

private enum FetchOutput: Sendable {
    case nonDraftMRs([MR])
    case draftMRs([MR])
    case sandcastleMRs([MR])
    case issues(open: [Issue], descriptions: [Int: String], all: [Issue])
    case worktrees([String])
    case mergedBranches([String])
    case todoistTodayOverdue([TodoistTask])
    case todoistUpNext([TodoistTask])
    case todoistFetchFailed(String)
    case failed(String)
}

private let defaultShell: ShellRunner = { command, dir in
    try shell(command, workingDirectory: dir)
}

// MARK: - Fetch helpers

private enum FailureKind {
    case fatal    // counts toward errors threshold (glab sources)
    case todoist  // non-fatal, surfaces as todoistError
}

private func fetchSource(
    _ command: String,
    dir: String?,
    label: String,
    runShell: ShellRunner,
    failureKind: FailureKind = .fatal,
    transform: (String) -> FetchOutput
) -> FetchOutput {
    do {
        let out = try runShell(command, dir)
        return transform(out)
    } catch {
        fputs("Warning: failed to fetch \(label) — \(error)\n", stderr)
        switch failureKind {
        case .fatal:   return .failed("\(error)")
        case .todoist: return .todoistFetchFailed("\(error)")
        }
    }
}

// MARK: - Public fetch

func fetchAllData(config: Config, runShell: @escaping ShellRunner = defaultShell) async -> FetchResult {
    let outputs: [FetchOutput] = await withTaskGroup(of: FetchOutput.self) { group in
        group.addTask {
            fetchSource("glab mr list --author=\(config.triageAuthor) --not-draft -F json --per-page 50",
                        dir: config.studioDir, label: "non-draft MRs", runShell: runShell) { out in
                .nonDraftMRs((decodeArray(out) as [RawMR]).map { MR(from: $0) })
            }
        }

        group.addTask {
            fetchSource("glab mr list --author=\(config.triageAuthor) --draft -F json --per-page 50",
                        dir: config.studioDir, label: "draft MRs", runShell: runShell) { out in
                .draftMRs((decodeArray(out) as [RawMR]).map { MR(from: $0) })
            }
        }

        group.addTask {
            fetchSource("glab mr list --author=\(config.triageAuthor) -F json --per-page 50 --repo ericmasiello/sandcastle-studio",
                        dir: config.studioDir, label: "sandcastle MRs", runShell: runShell) { out in
                .sandcastleMRs((decodeArray(out) as [RawMR]).map { MR(from: $0) })
            }
        }

        group.addTask {
            do {
                let out = try runShell("glab issue list -O json --per-page 100 --all", config.studioDir)
                let rawIssues: [RawIssue] = decodeArray(out)
                let all = rawIssues.map { Issue(from: $0) }
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

        // Non-fatal: worktree listing — empty result is fine if .worktrees doesn't exist
        group.addTask {
            let worktreePath = (config.studioDir as NSString).appendingPathComponent(".worktrees")
            let out = (try? runShell("ls '\(worktreePath)' 2>/dev/null", nil)) ?? ""
            let dirs = out.components(separatedBy: "\n").filter { !$0.isEmpty }
            return .worktrees(dirs)
        }

        // Non-fatal: merged branch detection — falls back to empty list
        group.addTask {
            let rawDefault = (try? runShell(
                "git -C '\(config.studioDir)' symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@'", nil)) ?? ""
            let defaultBranch = rawDefault.trimmingCharacters(in: .whitespacesAndNewlines)
            let branch = defaultBranch.isEmpty ? "master" : defaultBranch

            let branchOut = (try? runShell("git -C '\(config.studioDir)' branch -r --merged '\(branch)' 2>/dev/null", nil)) ?? ""
            let branches = branchOut
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains("->") }
            return .mergedBranches(branches)
        }

        // Non-fatal: Todoist today/overdue tasks — graceful degradation if td unavailable
        group.addTask {
            fetchSource("td task list --filter \"today | overdue\" --json",
                        dir: nil, label: "Todoist today/overdue tasks", runShell: runShell,
                        failureKind: .todoist) { out in
                .todoistTodayOverdue(decodeTodoistTasks(out))
            }
        }

        // Non-fatal: Todoist Up Next tasks — graceful degradation if td unavailable
        group.addTask {
            fetchSource("td task list --label \"Up Next\" --json",
                        dir: nil, label: "Todoist Up Next tasks", runShell: runShell,
                        failureKind: .todoist) { out in
                .todoistUpNext(decodeTodoistTasks(out))
            }
        }

        var results: [FetchOutput] = []
        for await output in group {
            results.append(output)
        }
        return results
    }

    var nonDraftMRs:    [MR] = []
    var draftMRs:       [MR] = []
    var sandcastleMRs:  [MR] = []
    var issuesList:     [Issue] = []
    var allIssuesList:  [Issue] = []
    var issueDescriptions: [Int: String] = [:]
    var worktreesList:  [String] = []
    var mergedBranches: [String] = []
    var errors: [String] = []
    var todoistTodayOverdueTasks: [TodoistTask]? = nil
    var todoistUpNextTasks: [TodoistTask]? = nil
    var todoistErrors: [String] = []

    for output in outputs {
        switch output {
        case .nonDraftMRs(let mrs):    nonDraftMRs = mrs
        case .draftMRs(let mrs):       draftMRs = mrs
        case .sandcastleMRs(let mrs):  sandcastleMRs = mrs
        case .issues(let open, let descriptions, let all):
            issuesList = open
            issueDescriptions = descriptions
            allIssuesList = all
        case .worktrees(let dirs):     worktreesList = dirs
        case .mergedBranches(let b):   mergedBranches = b
        case .todoistTodayOverdue(let tasks): todoistTodayOverdueTasks = tasks
        case .todoistUpNext(let tasks): todoistUpNextTasks = tasks
        case .todoistFetchFailed(let msg): todoistErrors.append(msg)
        case .failed(let desc):        errors.append(desc)
        }
    }

    if errors.count >= 4 {
        return .failure(errors)
    }

    let worktreeSet = Set(worktreesList)
    let filteredBranches = mergedBranches.filter { branch in
        let name = branch
            .split(separator: "/", maxSplits: 1)
            .last
            .map(String.init) ?? branch
        return worktreeSet.contains(name)
    }

    var todoistSnapshot: TodoistSnapshot? = nil
    var todoistError: String? = nil

    if !todoistErrors.isEmpty {
        todoistError = todoistErrors.first
    } else if let todayOverdue = todoistTodayOverdueTasks, let upNext = todoistUpNextTasks {
        let overdue = todayOverdue.filter { ($0.due?.date ?? "") < config.todayDate }
        let today = todayOverdue.filter { ($0.due?.date ?? "") >= config.todayDate }

        let todayOverdueIDs = Set(todayOverdue.map { $0.id })
        let dedupedUpNext = upNext.filter { !todayOverdueIDs.contains($0.id) }

        todoistSnapshot = TodoistSnapshot(overdue: overdue, today: today, upNext: dedupedUpNext)
    }

    let snapshot = Snapshot(
        nonDraftMrs: nonDraftMRs,
        draftMrs: draftMRs,
        sandcastleMrs: sandcastleMRs,
        issues: issuesList,
        worktrees: worktreesList,
        mergedBranches: filteredBranches,
        todoist: todoistSnapshot,
        todoistError: todoistError
    )

    return .success(snapshot: snapshot, issueDescriptions: issueDescriptions, allIssues: allIssuesList)
}

// MARK: - Snapshot reconciliation

func reconcileSnapshot(cached: Snapshot, fresh: Snapshot) -> Snapshot {
    var result = fresh
    if let todoistErr = fresh.todoistError, let cachedTodoist = cached.todoist {
        fputs("Warning: Todoist fetch failed (\(todoistErr)), using cached data\n", stderr)
        result.todoist = cachedTodoist
        result.todoistError = nil
    }
    return result
}
