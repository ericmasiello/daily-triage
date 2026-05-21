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


