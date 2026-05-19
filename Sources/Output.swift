import Foundation

func formatFull(reason: String, snapshot: Snapshot, analysis: AnalysisResult) -> String {
    var lines: [String] = []
    lines.append("MODE: FULL")
    lines.append("REASON: \(reason)")
    lines.append("")

    lines.append("---ANALYSIS---")
    let analysisEncoder = JSONEncoder()
    analysisEncoder.outputFormatting = [.sortedKeys]
    analysisEncoder.keyEncodingStrategy = .convertToSnakeCase
    if let analysisData = try? analysisEncoder.encode(analysis),
       let analysisString = String(data: analysisData, encoding: .utf8) {
        lines.append(analysisString)
    }
    lines.append("---END_ANALYSIS---")
    lines.append("")

    lines.append("---RAW_DATA---")

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.keyEncodingStrategy = .convertToSnakeCase
    if let jsonData = try? encoder.encode(snapshot),
       let jsonString = String(data: jsonData, encoding: .utf8) {
        lines.append(jsonString)
    }
    lines.append("---END_RAW_DATA---")

    return lines.joined(separator: "\n")
}

func formatNoChanges(ageMinutes: Int, report: String?, recommendation: String?) -> String {
    var lines: [String] = []
    lines.append("MODE: NO_CHANGES")
    lines.append("CACHE_AGE_MINUTES: \(ageMinutes)")
    lines.append("")
    lines.append("---PREVIOUS_REPORT---")
    lines.append(report ?? "(no report cached)")
    lines.append("---END_PREVIOUS_REPORT---")
    lines.append("")
    lines.append("PREVIOUS_RECOMMENDATION: \(recommendation ?? "(none)")")

    return lines.joined(separator: "\n")
}

func formatDelta(ageMinutes: Int, diff: DiffResult, report: String?, recommendation: String?) -> String {
    var lines: [String] = []
    lines.append("MODE: DELTA")
    lines.append("CACHE_AGE_MINUTES: \(ageMinutes)")
    lines.append("CHANGES_SUMMARY: \(diff.summary)")
    lines.append("")
    lines.append("---CHANGES---")
    for change in diff.changes {
        lines.append(change)
    }
    lines.append("---END_CHANGES---")
    lines.append("")
    lines.append("---PREVIOUS_REPORT---")
    lines.append(report ?? "(no report cached)")
    lines.append("---END_PREVIOUS_REPORT---")
    lines.append("")
    lines.append("PREVIOUS_RECOMMENDATION: \(recommendation ?? "(none)")")

    return lines.joined(separator: "\n")
}
