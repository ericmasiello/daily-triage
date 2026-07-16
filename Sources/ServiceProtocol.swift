import Foundation

/// How a data source handles fetch failures.
enum FailurePolicy {
    /// Counts toward the error threshold — exit 1 if enough sources fail.
    case fatal
    /// Fall back to cached data and warn on stderr.
    case degradable
    /// Skip without warning.
    case silent
}

/// Signals detected during a diff that may influence the output mode.
enum DiffSignal {
    /// A priority label (`p::*`) was added, removed, or changed.
    case priorityChange
}

struct DiffResult {
    var changes: [String] = []
    var signals: [DiffSignal] = []

    var isEmpty: Bool {
        changes.isEmpty
    }

    var summary: String {
        if isEmpty {
            return "no changes"
        }
        return changes.count == 1
            ? "1 change detected"
            : "\(changes.count) changes detected"
    }
}

/// A service that fetches, diffs, and formats one slice of triage data.
protocol DataSourceService {
    var label: String { get }
    var failurePolicy: FailurePolicy { get }

    mutating func fetch(config: Config, shell: @escaping ShellRunner) async throws
    func diff(cached: Snapshot, fresh: Snapshot) -> (changes: [String], signals: [DiffSignal])
    func format(_ snapshot: Snapshot) -> [String]
}
