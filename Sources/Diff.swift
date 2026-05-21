import Foundation

struct DiffResult {
    var changes: [String] = []
    var signals: [DiffSignal] = []

    var isEmpty: Bool { changes.isEmpty }

    var summary: String {
        if isEmpty { return "no changes" }
        return changes.count == 1
            ? "1 change detected"
            : "\(changes.count) changes detected"
    }
}

// MARK: - Todoist Diffing

func diffTodoist(cached: TodoistSnapshot?, fresh: TodoistSnapshot?) -> [String] {
    if cached == nil && fresh == nil { return [] }

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

private func flattenTodoist(_ snapshot: TodoistSnapshot?) -> [String: (String, TodoistTask)] {
    guard let s = snapshot else { return [:] }
    var result: [String: (String, TodoistTask)] = [:]
    for task in s.overdue { result[task.id] = ("overdue", task) }
    for task in s.today { result[task.id] = ("today", task) }
    for task in s.upNext { result[task.id] = ("up_next", task) }
    return result
}
