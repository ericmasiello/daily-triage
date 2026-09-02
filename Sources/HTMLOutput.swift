import Foundation

// MARK: - HTML report generation

/// Converts triage output text to a self-contained HTML page and writes it to disk.
/// Returns the path written, or throws on failure.
@discardableResult
func writeHTMLReport(_ text: String, config: Config) throws -> String {
    let html = renderHTML(from: text)
    let fm = FileManager.default
    if !fm.fileExists(atPath: config.cacheDir) {
        try fm.createDirectory(atPath: config.cacheDir, withIntermediateDirectories: true)
    }
    guard let data = html.data(using: .utf8) else {
        throw HTMLOutputError.encodingFailed
    }
    try data.write(to: URL(fileURLWithPath: config.htmlPath), options: .atomic)
    return config.htmlPath
}

func openHTML(path: String) {
    _ = try? shell("open \"\(path)\"")
}

enum HTMLOutputError: Error, CustomStringConvertible {
    case encodingFailed
    case writeFailed(Error)

    var description: String {
        switch self {
        case .encodingFailed: "failed to encode HTML as UTF-8"
        case let .writeFailed(e): "failed to write HTML file: \(e.localizedDescription)"
        }
    }
}

// MARK: - Renderer

private func renderHTML(from text: String) -> String {
    let mode = extractMode(from: text)
    let reason = extractValue(from: text, key: "REASON")
    let cacheAge = extractValue(from: text, key: "CACHE_AGE_MINUTES")
    let changesSummary = extractValue(from: text, key: "CHANGES_SUMMARY")
    let recommendation = extractRecommendation(from: text)
    let analysisJSON = extractBlock(from: text, start: "---ANALYSIS---", end: "---END_ANALYSIS---")
    let changesBlock = extractBlock(from: text, start: "---CHANGES---", end: "---END_CHANGES---")
    let previousReport = extractBlock(from: text, start: "---PREVIOUS_REPORT---", end: "---END_PREVIOUS_REPORT---")
    let previousRec = extractValue(from: text, key: "PREVIOUS_RECOMMENDATION")

    let timestamp = ISO8601DateFormatter().string(from: Date())
    let badge = modeBadge(mode)

    var sections: [String] = []

    // Header card
    sections.append("""
    <div class="header-card">
      <div class="header-top">
        <div>
          <h1>Triage Report</h1>
          <span class="timestamp">Generated \(htmlEscape(timestamp))</span>
        </div>
        \(badge)
      </div>
      \(metaRow(mode: mode, reason: reason, cacheAge: cacheAge, changesSummary: changesSummary))
    </div>
    """)

    // Recommendation callout (primary CTA)
    let recText = recommendation ?? previousRec
    if let rec = recText, !rec.isEmpty, rec != "(none)" {
        let clean = rec.hasPrefix("PREVIOUS_RECOMMENDATION:") ? String(rec.dropFirst("PREVIOUS_RECOMMENDATION:".count))
            .trimmingCharacters(in: .whitespaces) : rec
        sections.append("""
        <div class="recommendation-card">
          <div class="rec-label">Recommendation</div>
          <div class="rec-text">\(htmlEscape(clean))</div>
        </div>
        """)
    }

    // Analysis JSON → structured cards
    if let json = analysisJSON, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sections.append(renderAnalysis(json))
    }

    // Changes block (DELTA mode)
    if let changes = changesBlock, !changes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let changeItems = changes.components(separatedBy: "\n")
            .filter { !$0.isEmpty }
            .map { "<li>\(htmlEscape($0))</li>" }
            .joined(separator: "\n            ")
        sections.append("""
        <div class="section">
          <h2>Changes</h2>
          <ul class="changes-list">
            \(changeItems)
          </ul>
        </div>
        """)
    }

    // Previous report (NO_CHANGES / DELTA)
    if let report = previousReport, !report.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        sections.append("""
        <div class="section">
          <h2>Previous Report</h2>
          <div class="previous-report">\(markdownToHTML(report))</div>
        </div>
        """)
    }

    return htmlPage(title: "Triage Report", body: sections.joined(separator: "\n"))
}

// MARK: - Analysis section

private func renderAnalysis(_ jsonString: String) -> String {
    guard let data = jsonString.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return """
        <div class="section">
          <h2>Analysis</h2>
          <pre class="code-block">\(htmlEscape(jsonString))</pre>
        </div>
        """
    }

    var cards: [String] = []

    // Tier 1 MRs
    if let mrs = obj["tier_1_mrs"] as? [[String: Any]], !mrs.isEmpty {
        cards.append(mrTable(title: "Your MRs — Needs Action", mrs: mrs, accent: "tier1"))
    }

    if let drafts = obj["draft_mrs"] as? [[String: Any]], !drafts.isEmpty {
        cards.append(draftMrTable(drafts))
    }

    // Review queue — cross-repo MRs where the user is reviewer or assignee
    if let queue = obj["review_queue"] as? [[String: Any]], !queue.isEmpty {
        cards.append(reviewQueueTable(queue))
    }

    // Tier 2 issues
    if let issues = obj["tier_2_issues"] as? [[String: Any]], !issues.isEmpty {
        cards.append(tierIssueTable(title: "Near-Complete Workstreams", issues: issues, accent: "tier2"))
    }

    // Tier 3 issues
    if let issues = obj["tier_3_issues"] as? [[String: Any]], !issues.isEmpty {
        cards.append(tierIssueTable(title: "Remaining Issues", issues: issues, accent: "tier3"))
    }

    // Stale worktrees
    if let wt = obj["stale_worktrees"] as? [[String: Any]], !wt.isEmpty {
        cards.append(staleWorktreeList(wt))
    }

    // Merged branches
    if let branches = obj["merged_branches"] as? [String], !branches.isEmpty {
        cards.append("""
        <div class="analysis-card">
          <h3>Merged Branches to Clean Up</h3>
          <ul class="tag-list">
            \(branches.map { "<li class=\"tag\">\(htmlEscape($0))</li>" }.joined(separator: "\n            "))
          </ul>
        </div>
        """)
    }

    if cards.isEmpty {
        return ""
    }

    return """
    <div class="section">
      <h2>Analysis</h2>
      \(cards.joined(separator: "\n  "))
    </div>
    """
}

private func mrTable(title: String, mrs: [[String: Any]], accent: String) -> String {
    let rows = mrs.map { mr -> String in
        let iid = mr["iid"].flatMap { anyToString($0) } ?? "?"
        let mrTitle = mr["title"] as? String ?? ""
        let status = mr["review_status"] as? String ?? ""
        let age = mr["age_hours"].flatMap { anyToString($0) } ?? ""
        let url = mr["web_url"] as? String ?? ""
        let labels = (mr["labels"] as? [String] ?? []).filter { !$0.isEmpty }

        let iidLink = url.isEmpty ? "!\(iid)" : "<a href=\"\(htmlEscape(url))\" target=\"_blank\">!\(iid)</a>"
        let statusCls = htmlEscape(statusClass(status))
        let statusText = htmlEscape(statusLabel(status))
        let statusBadge = "<span class=\"status-badge status-\(statusCls)\">\(statusText)</span>"
        let ageText = age.isEmpty ? "" : "\(age)h"
        let labelBadges = labels
            .map { "<span class=\"label-badge\">\(htmlEscape($0))</span>" }
            .joined(separator: " ")
        let labelRow = labelBadges.isEmpty ? "" : "<div class=\"label-row\">\(labelBadges)</div>"

        return """
            <tr>
              <td class="mr-iid">\(iidLink)</td>
              <td class="mr-title">\(htmlEscape(mrTitle))\(labelRow)</td>
              <td>\(statusBadge)</td>
              <td class="mr-age">\(ageText)</td>
            </tr>
        """
    }
    let tableRows = rows.joined(separator: "\n")

    return """
    <div class="analysis-card analysis-card--\(accent)">
      <h3>\(htmlEscape(title))</h3>
      <table class="mr-table">
        <thead><tr><th>MR</th><th>Title</th><th>Status</th><th>Age</th></tr></thead>
        <tbody>
    \(tableRows)
        </tbody>
      </table>
    </div>
    """
}

private func reviewQueueTable(_ queue: [[String: Any]]) -> String {
    let rows = queue.map { mr -> String in
        let iid = mr["iid"].flatMap { anyToString($0) } ?? "?"
        let mrTitle = mr["title"] as? String ?? ""
        let repo = mr["repo"] as? String ?? ""
        let role = mr["role"] as? String ?? ""
        let age = mr["age_hours"].flatMap { anyToString($0) } ?? ""
        let url = mr["web_url"] as? String ?? ""

        let iidLink = url.isEmpty ? "!\(iid)" : "<a href=\"\(htmlEscape(url))\" target=\"_blank\">!\(iid)</a>"
        let ageText = age.isEmpty ? "" : "\(age)h"
        let roleClass = htmlEscape(role.replacingOccurrences(of: "+", with: "-"))
        let roleBadge = "<span class=\"status-badge status-\(roleClass)\">\(htmlEscape(role))</span>"

        return """
            <tr>
              <td class="mr-iid">\(iidLink)</td>
              <td class="mr-title">\(htmlEscape(mrTitle))<div class="muted">\(htmlEscape(repo))</div></td>
              <td>\(roleBadge)</td>
              <td class="mr-age">\(ageText)</td>
            </tr>
        """
    }
    let tableRows = rows.joined(separator: "\n")

    return """
    <div class="analysis-card analysis-card--tier1">
      <h3>Review Queue (\(queue.count))</h3>
      <table class="mr-table">
        <thead><tr><th>MR</th><th>Title</th><th>Role</th><th>Age</th></tr></thead>
        <tbody>
    \(tableRows)
        </tbody>
      </table>
    </div>
    """
}

private func draftMrTable(_ mrs: [[String: Any]]) -> String {
    let rows = mrs.map { mr -> String in
        let iid = mr["iid"].flatMap { anyToString($0) } ?? "?"
        let mrTitle = mr["title"] as? String ?? ""
        let notes = mr["user_notes_count"].flatMap { anyToString($0) } ?? "0"
        let age = mr["age_hours"].flatMap { anyToString($0) } ?? ""
        let url = mr["web_url"] as? String ?? ""

        let iidLink = url.isEmpty ? "!\(iid)" : "<a href=\"\(htmlEscape(url))\" target=\"_blank\">!\(iid)</a>"
        let ageText = age.isEmpty ? "" : "\(age)h"

        return """
            <tr>
              <td class="mr-iid">\(iidLink)</td>
              <td class="mr-title">\(htmlEscape(mrTitle))</td>
              <td>\(htmlEscape(notes))</td>
              <td class="mr-age">\(ageText)</td>
            </tr>
        """
    }
    let tableRows = rows.joined(separator: "\n")

    return """
    <div class="analysis-card analysis-card--draft">
      <h3>Your Draft MRs</h3>
      <table class="mr-table">
        <thead><tr><th>MR</th><th>Title</th><th>Notes</th><th>Age</th></tr></thead>
        <tbody>
    \(tableRows)
        </tbody>
      </table>
    </div>
    """
}

private func tierIssueTable(title: String, issues: [[String: Any]], accent: String) -> String {
    let rows = issues.map { issue -> String in
        // Jira issues are string-keyed (e.g. "ERICRULEZ-42"), not integer `iid`s like
        // GitLab MRs — the key already reads clearly without a "#" prefix.
        let key = issue["key"] as? String ?? "?"
        let issueTitle = issue["title"] as? String ?? ""
        let priority = issue["priority"] as? String ?? ""
        let completion = issue["workstream_completion"].flatMap { anyToString($0) }
        let url = issue["web_url"] as? String ?? ""

        let escapedKey = htmlEscape(key)
        let keyLink = url.isEmpty ? escapedKey : "<a href=\"\(htmlEscape(url))\" target=\"_blank\">\(escapedKey)</a>"
        let escapedTitle = htmlEscape(issueTitle)
        let titleContent = url.isEmpty
            ? escapedTitle
            : "<a href=\"\(htmlEscape(url))\" target=\"_blank\">\(escapedTitle)</a>"
        let priorityBadge = priority.isEmpty ? "" : "<span class=\"label-badge\">\(htmlEscape(priority))</span>"
        let completionText = completion.map { "<span class=\"muted\">\($0)% done</span>" } ?? ""

        return """
            <tr>
              <td class="mr-iid">\(keyLink)</td>
              <td class="mr-title">\(titleContent)</td>
              <td>\(priorityBadge) \(completionText)</td>
            </tr>
        """
    }
    let tableRows = rows.joined(separator: "\n")

    return """
    <div class="analysis-card analysis-card--\(accent)">
      <h3>\(htmlEscape(title))</h3>
      <table class="mr-table">
        <thead><tr><th>Issue</th><th>Title</th><th>Priority</th></tr></thead>
        <tbody>
    \(tableRows)
        </tbody>
      </table>
    </div>
    """
}

private func staleWorktreeList(_ worktrees: [[String: Any]]) -> String {
    let items = worktrees.map { wt -> String in
        let path = wt["path"] as? String ?? "?"
        let reason = (wt["reason"] as? String ?? "").replacingOccurrences(of: "_", with: " ")
        return "<li><code>\(htmlEscape(path))</code> <span class=\"muted\">— \(htmlEscape(reason))</span></li>"
    }
    let itemList = items.joined(separator: "\n          ")

    return """
    <div class="analysis-card analysis-card--warning">
      <h3>Stale Worktrees</h3>
      <ul class="worktree-list">
          \(itemList)
      </ul>
    </div>
    """
}

// MARK: - Simple markdown → HTML converter

private func closeListIfNeeded(_ html: inout [String], inList: inout Bool) {
    if inList {
        html.append("</ul>")
        inList = false
    }
}

private func appendMarkdownLine(_ line: String, to html: inout [String], inList: inout Bool) {
    if line.hasPrefix("# ") {
        closeListIfNeeded(&html, inList: &inList)
        html.append("<h2>\(inlineMarkdown(String(line.dropFirst(2))))</h2>")
    } else if line.hasPrefix("## ") {
        closeListIfNeeded(&html, inList: &inList)
        html.append("<h3>\(inlineMarkdown(String(line.dropFirst(3))))</h3>")
    } else if line.hasPrefix("### ") {
        closeListIfNeeded(&html, inList: &inList)
        html.append("<h4>\(inlineMarkdown(String(line.dropFirst(4))))</h4>")
    } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
        if !inList {
            html.append("<ul>"); inList = true
        }
        html.append("<li>\(inlineMarkdown(String(line.dropFirst(2))))</li>")
    } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
        closeListIfNeeded(&html, inList: &inList)
    } else {
        closeListIfNeeded(&html, inList: &inList)
        html.append("<p>\(inlineMarkdown(line))</p>")
    }
}

private func markdownToHTML(_ md: String) -> String {
    let lines = md.components(separatedBy: "\n")
    var html: [String] = []
    var inList = false
    var inCode = false
    var codeLang = ""
    var codeLines: [String] = []

    for line in lines {
        if line.hasPrefix("```") {
            if inCode {
                let escaped = codeLines.map { htmlEscape($0) }.joined(separator: "\n")
                html.append("<pre class=\"code-block\"><code class=\"lang-\(codeLang)\">\(escaped)</code></pre>")
                codeLines = []
                inCode = false
                codeLang = ""
            } else {
                closeListIfNeeded(&html, inList: &inList)
                inCode = true
                codeLang = htmlEscape(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
            continue
        }
        if inCode {
            codeLines.append(line)
            continue
        }
        appendMarkdownLine(line, to: &html, inList: &inList)
    }
    closeListIfNeeded(&html, inList: &inList)
    if inCode {
        let escaped = codeLines.map { htmlEscape($0) }.joined(separator: "\n")
        html.append("<pre class=\"code-block\"><code>\(escaped)</code></pre>")
    }
    return html.joined(separator: "\n")
}

private func inlineMarkdown(_ str: String) -> String {
    var result = htmlEscape(str)
    // Bold: **text** or __text__
    result = applyInlinePattern(result, pattern: "\\*\\*(.+?)\\*\\*", tag: "strong")
    result = applyInlinePattern(result, pattern: "__(.+?)__", tag: "strong")
    // Italic: *text* or _text_
    result = applyInlinePattern(result, pattern: "\\*(.+?)\\*", tag: "em")
    // Code: `text`
    result = applyInlineCode(result)
    // Links: [text](url)
    result = applyLinks(result)
    return result
}

private func applyInlinePattern(_ str: String, pattern: String, tag: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return str }
    let range = NSRange(str.startIndex..., in: str)
    return regex.stringByReplacingMatches(in: str, range: range, withTemplate: "<\(tag)>$1</\(tag)>")
}

private func applyInlineCode(_ str: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "`([^`]+)`") else { return str }
    let range = NSRange(str.startIndex..., in: str)
    return regex.stringByReplacingMatches(in: str, range: range, withTemplate: "<code>$1</code>")
}

private func applyLinks(_ str: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)") else { return str }
    let ns = str as NSString
    var result = ""
    var lastEnd = 0
    let matches = regex.matches(in: str, range: NSRange(str.startIndex..., in: str))
    for match in matches {
        let preRange = NSRange(location: lastEnd, length: match.range.location - lastEnd)
        result += ns.substring(with: preRange)
        let text = ns.substring(with: match.range(at: 1))
        let url = ns.substring(with: match.range(at: 2))
        result += "<a href=\"\(url)\" target=\"_blank\">\(text)</a>"
        lastEnd = match.range.location + match.range.length
    }
    result += ns.substring(from: lastEnd)
    return result
}

// MARK: - Text extraction helpers

private func extractMode(from text: String) -> String {
    for line in text.components(separatedBy: "\n") where line.hasPrefix("MODE: ") {
        return String(line.dropFirst(6))
    }
    return "UNKNOWN"
}

private func extractValue(from text: String, key: String) -> String? {
    for line in text.components(separatedBy: "\n") where line.hasPrefix("\(key): ") {
        return String(line.dropFirst(key.count + 2))
    }
    return nil
}

private func extractBlock(from text: String, start: String, end: String) -> String? {
    let lines = text.components(separatedBy: "\n")
    guard let startIdx = lines.firstIndex(of: start),
          let endIdx = lines.firstIndex(of: end),
          endIdx > startIdx else { return nil }
    return lines[(startIdx + 1) ..< endIdx].joined(separator: "\n")
}

private func extractRecommendation(from text: String) -> String? {
    guard let json = extractBlock(from: text, start: "---ANALYSIS---", end: "---END_ANALYSIS---"),
          let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let rec = obj["recommendation"] as? String else { return nil }
    return rec
}

// MARK: - UI helpers

private func modeBadge(_ mode: String) -> String {
    let (label, cls) = switch mode {
    case "FULL": ("Full Run", "badge-full")
    case "NO_CHANGES": ("No Changes", "badge-nochange")
    case "DELTA": ("Delta", "badge-delta")
    default: (mode, "badge-unknown")
    }
    return "<span class=\"mode-badge \(cls)\">\(label)</span>"
}

private func metaRow(mode _: String, reason: String?, cacheAge: String?, changesSummary: String?) -> String {
    var chips: [String] = []
    if let reasonText = reason {
        chips.append(metaChip("Reason", reasonText))
    }
    if let age = cacheAge {
        chips.append(metaChip("Cache age", "\(age) min"))
    }
    if let cs = changesSummary {
        chips.append(metaChip("Changes", cs))
    }
    guard !chips.isEmpty else { return "" }
    return "<div class=\"meta-row\">\(chips.joined())</div>"
}

private func metaChip(_ label: String, _ value: String) -> String {
    let escapedLabel = htmlEscape(label)
    let escapedValue = htmlEscape(value)
    return "<span class=\"meta-chip\">"
        + "<span class=\"meta-label\">\(escapedLabel)</span>"
        + "<span class=\"meta-value\">\(escapedValue)</span>"
        + "</span>"
}

private func statusClass(_ status: String) -> String {
    switch status {
    case "approved": "approved"
    case "changes_requested": "changes"
    case "awaiting_review": "awaiting"
    default: "other"
    }
}

private func statusLabel(_ status: String) -> String {
    switch status {
    case "approved": "Approved"
    case "changes_requested": "Changes Requested"
    case "awaiting_review": "Awaiting Review"
    default: status.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func anyToString(_ value: Any) -> String? {
    if let intVal = value as? Int {
        return String(intVal)
    }
    if let doubleVal = value as? Double {
        return String(Int(doubleVal))
    }
    if let strVal = value as? String {
        return strVal
    }
    return nil
}

func htmlEscape(_ str: String) -> String {
    str.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
