import Foundation

/// Result of diffing a cached snapshot against a fresh snapshot.
struct DiffResult {
    var changes: [String] = []
    var hasPriorityLabelChange: Bool = false

    var isEmpty: Bool { changes.isEmpty }

    /// Human-readable summary, e.g. "2 MR changes, 1 issue added"
    var summary: String {
        if isEmpty { return "no changes" }
        return changes.count == 1
            ? "1 change detected"
            : "\(changes.count) changes detected"
    }
}

/// Compare cached and fresh snapshots field-by-field.
/// Returns a DiffResult describing all changes.
func computeDiff(cached: [String: Any], fresh: [String: Any]) -> DiffResult {
    var result = DiffResult()

    diffMRCategory(&result, label: "MR", cached: cached["non_draft_mrs"], fresh: fresh["non_draft_mrs"])
    diffMRCategory(&result, label: "Draft MR", cached: cached["draft_mrs"], fresh: fresh["draft_mrs"])
    diffMRCategory(&result, label: "Sandcastle MR", cached: cached["sandcastle_mrs"], fresh: fresh["sandcastle_mrs"])
    diffIssues(&result, cached: cached["issues"], fresh: fresh["issues"])
    diffStringSet(&result, label: "Worktree", cached: cached["worktrees"], fresh: fresh["worktrees"])
    diffStringSet(&result, label: "Merged branch", cached: cached["merged_branches"], fresh: fresh["merged_branches"])

    return result
}

// MARK: - MR Diffing

private func diffMRCategory(_ result: inout DiffResult, label: String,
                             cached: Any?, fresh: Any?) {
    let cachedMRs = (cached as? [[String: Any]]) ?? []
    let freshMRs = (fresh as? [[String: Any]]) ?? []

    let cachedByIID = indexByIID(cachedMRs)
    let freshByIID = indexByIID(freshMRs)

    let cachedIIDs = Set(cachedByIID.keys)
    let freshIIDs = Set(freshByIID.keys)

    for iid in freshIIDs.subtracting(cachedIIDs).sorted() {
        let title = freshByIID[iid]?["title"] as? String ?? ""
        result.changes.append("\(label) !\(iid): added (\(title))")
    }

    for iid in cachedIIDs.subtracting(freshIIDs).sorted() {
        let title = cachedByIID[iid]?["title"] as? String ?? ""
        result.changes.append("\(label) !\(iid): removed (\(title))")
    }

    let trackedFields = ["detailed_merge_status", "has_conflicts", "user_notes_count", "labels"]
    for iid in cachedIIDs.intersection(freshIIDs).sorted() {
        guard let oldMR = cachedByIID[iid], let newMR = freshByIID[iid] else { continue }
        for field in trackedFields {
            let oldVal = oldMR[field]
            let newVal = newMR[field]
            if !jsonEqual(oldVal, newVal) {
                let oldStr = describeValue(oldVal)
                let newStr = describeValue(newVal)
                result.changes.append("\(label) !\(iid): \(field) changed \(oldStr) → \(newStr)")
            }
        }
    }
}

// MARK: - Issue Diffing

private func diffIssues(_ result: inout DiffResult, cached: Any?, fresh: Any?) {
    let cachedIssues = (cached as? [[String: Any]]) ?? []
    let freshIssues = (fresh as? [[String: Any]]) ?? []

    let cachedByIID = indexByIID(cachedIssues)
    let freshByIID = indexByIID(freshIssues)

    let cachedIIDs = Set(cachedByIID.keys)
    let freshIIDs = Set(freshByIID.keys)

    for iid in freshIIDs.subtracting(cachedIIDs).sorted() {
        let title = freshByIID[iid]?["title"] as? String ?? ""
        result.changes.append("Issue #\(iid): added (\(title))")
    }

    for iid in cachedIIDs.subtracting(freshIIDs).sorted() {
        let title = cachedByIID[iid]?["title"] as? String ?? ""
        result.changes.append("Issue #\(iid): removed (\(title))")
    }

    for iid in cachedIIDs.intersection(freshIIDs).sorted() {
        guard let oldIssue = cachedByIID[iid], let newIssue = freshByIID[iid] else { continue }

        let oldLabels = Set((oldIssue["labels"] as? [String]) ?? [])
        let newLabels = Set((newIssue["labels"] as? [String]) ?? [])

        if oldLabels != newLabels {
            let added = newLabels.subtracting(oldLabels)
            let removed = oldLabels.subtracting(newLabels)

            let priorityAdded = added.filter { $0.hasPrefix("p::") }
            let priorityRemoved = removed.filter { $0.hasPrefix("p::") }
            if !priorityAdded.isEmpty || !priorityRemoved.isEmpty {
                result.hasPriorityLabelChange = true
            }

            var parts: [String] = []
            if !added.isEmpty {
                parts.append("added \(added.sorted().joined(separator: ", "))")
            }
            if !removed.isEmpty {
                parts.append("removed \(removed.sorted().joined(separator: ", "))")
            }
            result.changes.append("Issue #\(iid): labels \(parts.joined(separator: "; "))")
        }
    }

    for iid in freshIIDs.subtracting(cachedIIDs) {
        let labels = (freshByIID[iid]?["labels"] as? [String]) ?? []
        if labels.contains(where: { $0.hasPrefix("p::") }) {
            result.hasPriorityLabelChange = true
        }
    }
    for iid in cachedIIDs.subtracting(freshIIDs) {
        let labels = (cachedByIID[iid]?["labels"] as? [String]) ?? []
        if labels.contains(where: { $0.hasPrefix("p::") }) {
            result.hasPriorityLabelChange = true
        }
    }
}

// MARK: - String Set Diffing (worktrees, merged branches)

private func diffStringSet(_ result: inout DiffResult, label: String,
                            cached: Any?, fresh: Any?) {
    let cachedSet = Set((cached as? [String]) ?? [])
    let freshSet = Set((fresh as? [String]) ?? [])

    for item in freshSet.subtracting(cachedSet).sorted() {
        result.changes.append("\(label): added \(item)")
    }
    for item in cachedSet.subtracting(freshSet).sorted() {
        result.changes.append("\(label): removed \(item)")
    }
}

// MARK: - Helpers

/// Index an array of dictionaries by their "iid" field (as Int).
private func indexByIID(_ items: [[String: Any]]) -> [Int: [String: Any]] {
    var dict: [Int: [String: Any]] = [:]
    for item in items {
        if let iid = item["iid"] as? Int {
            dict[iid] = item
        }
    }
    return dict
}

/// Compare two JSON-compatible values for equality.
private func jsonEqual(_ a: Any?, _ b: Any?) -> Bool {
    switch (a, b) {
    case (nil, nil):
        return true
    case (nil, _), (_, nil):
        return false
    case (let a as String, let b as String):
        return a == b
    case (let a as Int, let b as Int):
        return a == b
    case (let a as Double, let b as Double):
        return a == b
    case (let a as Bool, let b as Bool):
        return a == b
    case (let a as [String], let b as [String]):
        return a == b
    case (let a as [Any], let b as [Any]):
        guard a.count == b.count else { return false }
        return zip(a, b).allSatisfy { jsonEqual($0, $1) }
    default:
        guard let aData = try? JSONSerialization.data(withJSONObject: a as Any, options: .sortedKeys),
              let bData = try? JSONSerialization.data(withJSONObject: b as Any, options: .sortedKeys) else {
            return false
        }
        return aData == bData
    }
}

/// Describe a JSON value as a short string for change descriptions.
private func describeValue(_ val: Any?) -> String {
    guard let val = val else { return "null" }
    if let s = val as? String { return s }
    if let n = val as? Int { return "\(n)" }
    if let b = val as? Bool { return b ? "true" : "false" }
    if let arr = val as? [String] { return "[\(arr.joined(separator: ", "))]" }
    return "\(val)"
}
