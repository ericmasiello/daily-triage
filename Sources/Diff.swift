import Foundation

struct DiffResult {
    var changes: [String] = []
    var hasPriorityLabelChange: Bool = false

    var isEmpty: Bool { changes.isEmpty }

    var summary: String {
        if isEmpty { return "no changes" }
        return changes.count == 1
            ? "1 change detected"
            : "\(changes.count) changes detected"
    }
}

func computeDiff(cached: Snapshot, fresh: Snapshot) -> DiffResult {
    var result = DiffResult()

    diffMRs(&result, label: "MR", cached: cached.nonDraftMrs, fresh: fresh.nonDraftMrs)
    diffMRs(&result, label: "Draft MR", cached: cached.draftMrs, fresh: fresh.draftMrs)
    diffMRs(&result, label: "Sandcastle MR", cached: cached.sandcastleMrs, fresh: fresh.sandcastleMrs)
    diffIssues(&result, cached: cached.issues, fresh: fresh.issues)
    diffStringSet(&result, label: "Worktree", cached: cached.worktrees, fresh: fresh.worktrees)
    diffStringSet(&result, label: "Merged branch", cached: cached.mergedBranches, fresh: fresh.mergedBranches)
    diffTodoist(&result, cached: cached.todoist, fresh: fresh.todoist)

    return result
}

// MARK: - MR Diffing

private func diffMRs(_ result: inout DiffResult, label: String, cached: [MR], fresh: [MR]) {
    let cachedByIID = Dictionary(cached.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })
    let freshByIID = Dictionary(fresh.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })

    let cachedIIDs = Set(cachedByIID.keys)
    let freshIIDs = Set(freshByIID.keys)

    for iid in freshIIDs.subtracting(cachedIIDs).sorted() {
        result.changes.append("\(label) !\(iid): added (\(freshByIID[iid]!.title))")
    }

    for iid in cachedIIDs.subtracting(freshIIDs).sorted() {
        result.changes.append("\(label) !\(iid): removed (\(cachedByIID[iid]!.title))")
    }

    for iid in cachedIIDs.intersection(freshIIDs).sorted() {
        let old = cachedByIID[iid]!
        let new = freshByIID[iid]!

        if old.detailedMergeStatus != new.detailedMergeStatus {
            result.changes.append(
                "\(label) !\(iid): detailed_merge_status changed \(old.detailedMergeStatus ?? "null") → \(new.detailedMergeStatus ?? "null")")
        }
        if old.hasConflicts != new.hasConflicts {
            result.changes.append(
                "\(label) !\(iid): has_conflicts changed \(describeOptional(old.hasConflicts)) → \(describeOptional(new.hasConflicts))")
        }
        if old.userNotesCount != new.userNotesCount {
            result.changes.append(
                "\(label) !\(iid): user_notes_count changed \(describeOptional(old.userNotesCount)) → \(describeOptional(new.userNotesCount))")
        }
        if old.labels != new.labels {
            result.changes.append(
                "\(label) !\(iid): labels changed [\(old.labels.joined(separator: ", "))] → [\(new.labels.joined(separator: ", "))]")
        }
    }
}

// MARK: - Issue Diffing

private func diffIssues(_ result: inout DiffResult, cached: [Issue], fresh: [Issue]) {
    let cachedByIID = Dictionary(cached.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })
    let freshByIID = Dictionary(fresh.map { ($0.iid, $0) }, uniquingKeysWith: { _, b in b })

    let cachedIIDs = Set(cachedByIID.keys)
    let freshIIDs = Set(freshByIID.keys)

    for iid in freshIIDs.subtracting(cachedIIDs).sorted() {
        result.changes.append("Issue #\(iid): added (\(freshByIID[iid]!.title))")
    }

    for iid in cachedIIDs.subtracting(freshIIDs).sorted() {
        result.changes.append("Issue #\(iid): removed (\(cachedByIID[iid]!.title))")
    }

    for iid in cachedIIDs.intersection(freshIIDs).sorted() {
        let old = cachedByIID[iid]!
        let new = freshByIID[iid]!

        let oldLabels = Set(old.labels)
        let newLabels = Set(new.labels)

        if oldLabels != newLabels {
            let added = newLabels.subtracting(oldLabels)
            let removed = oldLabels.subtracting(newLabels)

            if added.contains(where: { $0.hasPrefix("p::") }) || removed.contains(where: { $0.hasPrefix("p::") }) {
                result.hasPriorityLabelChange = true
            }

            var parts: [String] = []
            if !added.isEmpty { parts.append("added \(added.sorted().joined(separator: ", "))") }
            if !removed.isEmpty { parts.append("removed \(removed.sorted().joined(separator: ", "))") }
            result.changes.append("Issue #\(iid): labels \(parts.joined(separator: "; "))")
        }
    }

    for iid in freshIIDs.subtracting(cachedIIDs) {
        if freshByIID[iid]!.labels.contains(where: { $0.hasPrefix("p::") }) {
            result.hasPriorityLabelChange = true
        }
    }
    for iid in cachedIIDs.subtracting(freshIIDs) {
        if cachedByIID[iid]!.labels.contains(where: { $0.hasPrefix("p::") }) {
            result.hasPriorityLabelChange = true
        }
    }
}

// MARK: - String Set Diffing

private func diffStringSet(_ result: inout DiffResult, label: String,
                            cached: [String], fresh: [String]) {
    let cachedSet = Set(cached)
    let freshSet = Set(fresh)

    for item in freshSet.subtracting(cachedSet).sorted() {
        result.changes.append("\(label): added \(item)")
    }
    for item in cachedSet.subtracting(freshSet).sorted() {
        result.changes.append("\(label): removed \(item)")
    }
}

// MARK: - Helpers

private func describeOptional<T>(_ value: T?) -> String {
    guard let value = value else { return "null" }
    return "\(value)"
}

// MARK: - Todoist Diffing

private func diffTodoist(_ result: inout DiffResult, cached: TodoistSnapshot?, fresh: TodoistSnapshot?) {
    if cached == nil && fresh == nil { return }

    let cachedTasks = flattenTodoist(cached)
    let freshTasks = flattenTodoist(fresh)

    let cachedIDs = Set(cachedTasks.keys)
    let freshIDs = Set(freshTasks.keys)

    for id in freshIDs.subtracting(cachedIDs).sorted() {
        let (_, task) = freshTasks[id]!
        result.changes.append("Todoist: added (\(task.content))")
    }

    for id in cachedIDs.subtracting(freshIDs).sorted() {
        let (_, task) = cachedTasks[id]!
        result.changes.append("Todoist: removed (\(task.content))")
    }

    for id in cachedIDs.intersection(freshIDs).sorted() {
        let (oldCat, oldTask) = cachedTasks[id]!
        let (newCat, newTask) = freshTasks[id]!

        if oldTask.content != newTask.content {
            result.changes.append("Todoist \(id): content changed \"\(oldTask.content)\" → \"\(newTask.content)\"")
        }
        if oldTask.priority != newTask.priority {
            result.changes.append("Todoist \(id): priority changed \(oldTask.priority) → \(newTask.priority)")
        }
        if oldCat != newCat {
            result.changes.append("Todoist \(id): moved \(oldCat) → \(newCat)")
        }
    }
}

private func flattenTodoist(_ snapshot: TodoistSnapshot?) -> [String: (String, TodoistTask)] {
    guard let s = snapshot else { return [:] }
    var result: [String: (String, TodoistTask)] = [:]
    for task in s.overdue { result[task.id] = ("overdue", task) }
    for task in s.today { result[task.id] = ("today", task) }
    for task in s.upNext { result[task.id] = ("up_next", task) }
    return result
}
