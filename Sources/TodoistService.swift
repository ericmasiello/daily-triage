import Foundation

// MARK: - Todoist value types

struct TodoistTask: Codable, Equatable {
    let id: String
    let content: String
    let priority: Int
    let due: TodoistDue?
    let labels: [String]
    let url: String
}

struct TodoistDue: Codable, Equatable {
    let date: String
    let isRecurring: Bool
    let string: String?
}

// MARK: - Todoist Service

struct TodoistService: DataSourceService {
    let label = "todoist"
    let failurePolicy: FailurePolicy = .degradable

    struct State: Codable, Equatable {
        var overdue: [TodoistTask]
        var today: [TodoistTask]
        var upNext: [TodoistTask]
    }

    private(set) var fetchedState: State?
    private(set) var fetchError: String?

    // MARK: - Protocol: fetch

    mutating func fetch(config: Config, shell: @escaping ShellRunner) async throws {
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

        var todayOverdueTasks: [TodoistTask]?
        var upNextTasks: [TodoistTask]?
        var errors: [String] = []

        for output in outputs {
            switch output {
            case let .todayOverdue(tasks): todayOverdueTasks = tasks
            case let .upNext(tasks): upNextTasks = tasks
            case let .failed(msg): errors.append(msg)
            }
        }

        if !errors.isEmpty {
            fetchError = errors.first
            fetchedState = nil
            return
        }

        guard let todayOverdue = todayOverdueTasks, let upNext = upNextTasks else {
            fetchedState = nil
            return
        }

        let overdue = todayOverdue.filter { ($0.due?.date ?? "") < config.todayDate }
        let today = todayOverdue.filter { ($0.due?.date ?? "") >= config.todayDate }

        let todayOverdueIDs = Set(todayOverdue.map(\.id))
        let dedupedUpNext = upNext.filter { !todayOverdueIDs.contains($0.id) }

        fetchedState = State(overdue: overdue, today: today, upNext: dedupedUpNext)
        fetchError = nil
    }

    // MARK: - Protocol: diff

    func diff(cached: Snapshot, fresh: Snapshot) -> (changes: [String], signals: [DiffSignal]) {
        let changes = diffTodoist(cached: cached.todoist, fresh: fresh.todoist)
        return (changes, [])
    }

    // MARK: - Protocol: format

    func format(_: Snapshot) -> [String] {
        []
    }

    // MARK: - Reconciliation

    mutating func reconcileIfNeeded(cached: Snapshot) {
        if let err = fetchError, let cachedTodoist = cached.todoist {
            fputs("Warning: Todoist fetch failed (\(err)), using cached data\n", stderr)
            fetchedState = cachedTodoist
            fetchError = nil
        }
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
            due: raw.due
                .map { TodoistDue(date: $0.date, isRecurring: $0.isRecurring, string: $0.string) },
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

// MARK: - Fetch internals

private enum TodoistFetchOutput: Sendable {
    case todayOverdue([TodoistTask])
    case upNext([TodoistTask])
    case failed(String)
}

// MARK: - Diff internals

private func diffTodoist(cached: TodoistService.State?, fresh: TodoistService.State?) -> [String] {
    if cached == nil && fresh == nil {
        return []
    }

    let cachedTasks = flattenTodoist(cached)
    let freshTasks = flattenTodoist(fresh)

    let cachedIDs = Set(cachedTasks.keys)
    let freshIDs = Set(freshTasks.keys)

    var changes: [String] = []

    for id in freshIDs.subtracting(cachedIDs).sorted() {
        let (_, task) = freshTasks[id]!
        changes.append("Todoist: added (\(task.content))")
    }

    for id in cachedIDs.subtracting(freshIDs).sorted() {
        let (_, task) = cachedTasks[id]!
        changes.append("Todoist: removed (\(task.content))")
    }

    for id in cachedIDs.intersection(freshIDs).sorted() {
        let (oldCat, oldTask) = cachedTasks[id]!
        let (newCat, newTask) = freshTasks[id]!

        if oldTask.content != newTask.content {
            changes.append("Todoist \(id): content changed \"\(oldTask.content)\" → \"\(newTask.content)\"")
        }
        if oldTask.priority != newTask.priority {
            changes.append("Todoist \(id): priority changed \(oldTask.priority) → \(newTask.priority)")
        }
        if oldCat != newCat {
            changes.append("Todoist \(id): moved \(oldCat) → \(newCat)")
        }
    }

    return changes
}

private func flattenTodoist(_ snapshot: TodoistService.State?) -> [String: (String, TodoistTask)] {
    guard let snapshot else { return [:] }
    var result: [String: (String, TodoistTask)] = [:]
    for task in snapshot.overdue {
        result[task.id] = ("overdue", task)
    }
    for task in snapshot.today {
        result[task.id] = ("today", task)
    }
    for task in snapshot.upNext {
        result[task.id] = ("up_next", task)
    }
    return result
}
