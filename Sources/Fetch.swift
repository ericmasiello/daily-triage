import Foundation

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

private func decodeTodoistTasks(_ string: String) -> [TodoistTask] {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return [] }
    let decoder = JSONDecoder()
    guard let response = try? decoder.decode(RawTodoistResponse.self, from: data) else { return [] }
    return response.results.map { TodoistTask(from: $0) }
}

// MARK: - Todoist fetch

struct TodoistFetchResult {
    var snapshot: TodoistSnapshot?
    var error: String?
}

private enum TodoistFetchOutput: Sendable {
    case todayOverdue([TodoistTask])
    case upNext([TodoistTask])
    case failed(String)
}

func fetchTodoistData(config: Config, shell: @escaping ShellRunner) async -> TodoistFetchResult {
    let outputs: [TodoistFetchOutput] = await withTaskGroup(of: TodoistFetchOutput.self) { group in
        group.addTask {
            do {
                let out = try shell("td task list --filter \"today | overdue\" --json", nil)
                return .todayOverdue(decodeTodoistTasks(out))
            } catch {
                fputs("Warning: failed to fetch Todoist today/overdue tasks — \(error)\n", stderr)
                return .failed("\(error)")
            }
        }

        group.addTask {
            do {
                let out = try shell("td task list --label \"Up Next\" --json", nil)
                return .upNext(decodeTodoistTasks(out))
            } catch {
                fputs("Warning: failed to fetch Todoist Up Next tasks — \(error)\n", stderr)
                return .failed("\(error)")
            }
        }

        var results: [TodoistFetchOutput] = []
        for await output in group {
            results.append(output)
        }
        return results
    }

    var todayOverdueTasks: [TodoistTask]? = nil
    var upNextTasks: [TodoistTask]? = nil
    var errors: [String] = []

    for output in outputs {
        switch output {
        case .todayOverdue(let tasks): todayOverdueTasks = tasks
        case .upNext(let tasks): upNextTasks = tasks
        case .failed(let msg): errors.append(msg)
        }
    }

    if !errors.isEmpty {
        return TodoistFetchResult(snapshot: nil, error: errors.first)
    }

    guard let todayOverdue = todayOverdueTasks, let upNext = upNextTasks else {
        return TodoistFetchResult(snapshot: nil, error: nil)
    }

    let overdue = todayOverdue.filter { ($0.due?.date ?? "") < config.todayDate }
    let today = todayOverdue.filter { ($0.due?.date ?? "") >= config.todayDate }

    let todayOverdueIDs = Set(todayOverdue.map { $0.id })
    let dedupedUpNext = upNext.filter { !todayOverdueIDs.contains($0.id) }

    return TodoistFetchResult(
        snapshot: TodoistSnapshot(overdue: overdue, today: today, upNext: dedupedUpNext),
        error: nil
    )
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
