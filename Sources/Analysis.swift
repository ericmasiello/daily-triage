import Foundation

// MARK: - Analysis Output Types

struct ChildInfo: Codable {
    let iid: Int
    let state: String
}

struct CompletionInfo: Codable {
    let closed: Int
    let total: Int
    let percentage: Int
}

struct PRDHierarchyEntry: Codable {
    let prdIid: Int
    let title: String
    let children: [ChildInfo]
    let completion: CompletionInfo
}

struct AnalysisResult: Codable {
    let prdHierarchy: [PRDHierarchyEntry]
}

// MARK: - Analysis Engine

func computeAnalysis(snapshot: Snapshot, issueDescriptions: [Int: String], allIssues: [Issue]) -> AnalysisResult {
    let issuesByIID = Dictionary(
        allIssues.map { ($0.iid, $0) },
        uniquingKeysWith: { _, b in b }
    )

    var parentToChildren: [Int: [Int]] = [:]

    for (iid, description) in issueDescriptions {
        for parentIID in parseParentReferences(description) {
            parentToChildren[parentIID, default: []].append(iid)
        }
    }

    var entries: [PRDHierarchyEntry] = []

    for prdIID in parentToChildren.keys.sorted() {
        let childIIDs = parentToChildren[prdIID]!.sorted()
        let title = issuesByIID[prdIID]?.title ?? "Unknown issue #\(prdIID)"

        let children: [ChildInfo] = childIIDs.map { childIID in
            let state: String
            if let issue = issuesByIID[childIID] {
                state = issue.state ?? "opened"
            } else {
                state = "closed"
            }
            return ChildInfo(iid: childIID, state: state)
        }

        let closedCount = children.filter { $0.state == "closed" }.count
        let total = children.count
        let percentage = total > 0 ? (closedCount * 100) / total : 0

        entries.append(PRDHierarchyEntry(
            prdIid: prdIID,
            title: title,
            children: children,
            completion: CompletionInfo(closed: closedCount, total: total, percentage: percentage)
        ))
    }

    return AnalysisResult(prdHierarchy: entries)
}

// MARK: - Description Parsing

/// Extracts parent PRD IIDs from an issue description.
/// Patterns: `## Parent PRD` section with `#IID`, `Related to #IID`.
private func parseParentReferences(_ description: String) -> [Int] {
    var parents: [Int] = []
    let lines = description.components(separatedBy: "\n")

    var inParentPRDSection = false

    for line in lines {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        if trimmed.hasPrefix("## Parent PRD") {
            inParentPRDSection = true
            for iid in extractIIDs(from: trimmed, afterPrefix: "## Parent PRD") {
                parents.append(iid)
            }
            continue
        }

        if trimmed.hasPrefix("##") {
            inParentPRDSection = false
            continue
        }

        if inParentPRDSection {
            for iid in extractAllIIDs(from: trimmed) {
                parents.append(iid)
            }
            continue
        }

        if let range = trimmed.range(of: "Related to #", options: .caseInsensitive) {
            let afterHash = trimmed[range.upperBound...]
            if let iid = parseLeadingInt(String(afterHash)) {
                parents.append(iid)
            }
        }
    }

    var seen = Set<Int>()
    return parents.filter { seen.insert($0).inserted }
}

private func extractIIDs(from line: String, afterPrefix prefix: String) -> [Int] {
    guard let range = line.range(of: prefix) else { return [] }
    let remainder = String(line[range.upperBound...])
    return extractAllIIDs(from: remainder)
}

private func extractAllIIDs(from text: String) -> [Int] {
    var results: [Int] = []
    var i = text.startIndex

    while i < text.endIndex {
        if text[i] == "#" {
            let afterHash = text.index(after: i)
            if afterHash < text.endIndex {
                var end = afterHash
                while end < text.endIndex && text[end].isNumber {
                    end = text.index(after: end)
                }
                if end > afterHash, let iid = Int(text[afterHash..<end]) {
                    results.append(iid)
                    i = end
                    continue
                }
            }
        }
        i = text.index(after: i)
    }

    return results
}

private func parseLeadingInt(_ s: String) -> Int? {
    var end = s.startIndex
    while end < s.endIndex && s[end].isNumber {
        end = s.index(after: end)
    }
    guard end > s.startIndex else { return nil }
    return Int(s[s.startIndex..<end])
}
