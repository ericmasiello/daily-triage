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
        sections.append("""
        <div class="section">
          <h2>Changes</h2>
          <ul class="changes-list">
            \(changes.components(separatedBy: "\n").filter { !$0.isEmpty }.map { "<li>\(htmlEscape($0))</li>" }
            .joined(separator: "\n            "))
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
        cards.append(mrTable(title: "Tier 1 — Ready to Merge / Needs Action", mrs: mrs, accent: "tier1"))
    }

    // Tier 2 MRs
    if let mrs = obj["tier_2_mrs"] as? [[String: Any]], !mrs.isEmpty {
        cards.append(mrTable(title: "Tier 2 — In Progress", mrs: mrs, accent: "tier2"))
    }

    // Issues
    if let issues = obj["issues"] as? [[String: Any]], !issues.isEmpty {
        cards.append(issueTable(issues))
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
        let statusBadge = "<span class=\"status-badge status-\(htmlEscape(statusClass(status)))\">\(htmlEscape(statusLabel(status)))</span>"
        let ageText = age.isEmpty ? "" : "\(age)h"
        let labelBadges = labels.map { "<span class=\"label-badge\">\(htmlEscape($0))</span>" }.joined(separator: " ")

        return """
            <tr>
              <td class="mr-iid">\(iidLink)</td>
              <td class="mr-title">\(htmlEscape(mrTitle))\(labelBadges
            .isEmpty ? "" : "<div class=\"label-row\">\(labelBadges)</div>")</td>
              <td>\(statusBadge)</td>
              <td class="mr-age">\(ageText)</td>
            </tr>
        """
    }.joined(separator: "\n")

    return """
    <div class="analysis-card analysis-card--\(accent)">
      <h3>\(htmlEscape(title))</h3>
      <table class="mr-table">
        <thead><tr><th>MR</th><th>Title</th><th>Status</th><th>Age</th></tr></thead>
        <tbody>
    \(rows)
        </tbody>
      </table>
    </div>
    """
}

private func issueTable(_ issues: [[String: Any]]) -> String {
    let rows = issues.map { issue -> String in
        let iid = issue["iid"].flatMap { anyToString($0) } ?? "?"
        let title = issue["title"] as? String ?? ""
        let tier = issue["tier"].flatMap { anyToString($0) } ?? ""
        let url = issue["web_url"] as? String ?? ""
        let labels = (issue["labels"] as? [String] ?? []).filter { !$0.isEmpty }

        let iidLink = url.isEmpty ? "#\(iid)" : "<a href=\"\(htmlEscape(url))\" target=\"_blank\">#\(iid)</a>"
        let tierBadge = tier.isEmpty ? "" : "<span class=\"tier-badge\">p::\(tier)</span>"
        let labelBadges = labels.map { "<span class=\"label-badge\">\(htmlEscape($0))</span>" }.joined(separator: " ")

        return """
            <tr>
              <td class="mr-iid">\(iidLink)</td>
              <td class="mr-title">\(htmlEscape(title))\(labelBadges
            .isEmpty ? "" : "<div class=\"label-row\">\(labelBadges)</div>")</td>
              <td>\(tierBadge)</td>
            </tr>
        """
    }.joined(separator: "\n")

    return """
    <div class="analysis-card">
      <h3>Issues</h3>
      <table class="mr-table">
        <thead><tr><th>Issue</th><th>Title</th><th>Priority</th></tr></thead>
        <tbody>
    \(rows)
        </tbody>
      </table>
    </div>
    """
}

private func staleWorktreeList(_ worktrees: [[String: Any]]) -> String {
    let items = worktrees.map { wt -> String in
        let path = wt["path"] as? String ?? "?"
        let reason = wt["reason"] as? String ?? ""
        return "<li><code>\(htmlEscape(path))</code> <span class=\"muted\">— \(htmlEscape(reason.replacingOccurrences(of: "_", with: " ")))</span></li>"
    }.joined(separator: "\n          ")

    return """
    <div class="analysis-card analysis-card--warning">
      <h3>Stale Worktrees</h3>
      <ul class="worktree-list">
          \(items)
      </ul>
    </div>
    """
}

// MARK: - Simple markdown → HTML converter

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
                if inList {
                    html.append("</ul>"); inList = false
                }
                inCode = true
                codeLang = htmlEscape(String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces))
            }
            continue
        }
        if inCode {
            codeLines.append(line)
            continue
        }
        if line.hasPrefix("# ") {
            if inList {
                html.append("</ul>"); inList = false
            }
            html.append("<h2>\(inlineMarkdown(String(line.dropFirst(2))))</h2>")
        } else if line.hasPrefix("## ") {
            if inList {
                html.append("</ul>"); inList = false
            }
            html.append("<h3>\(inlineMarkdown(String(line.dropFirst(3))))</h3>")
        } else if line.hasPrefix("### ") {
            if inList {
                html.append("</ul>"); inList = false
            }
            html.append("<h4>\(inlineMarkdown(String(line.dropFirst(4))))</h4>")
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            if !inList {
                html.append("<ul>"); inList = true
            }
            html.append("<li>\(inlineMarkdown(String(line.dropFirst(2))))</li>")
        } else if line.trimmingCharacters(in: .whitespaces).isEmpty {
            if inList {
                html.append("</ul>"); inList = false
            }
            html.append("<br>")
        } else {
            if inList {
                html.append("</ul>"); inList = false
            }
            html.append("<p>\(inlineMarkdown(line))</p>")
        }
    }
    if inList {
        html.append("</ul>")
    }
    if inCode {
        let escaped = codeLines.map { htmlEscape($0) }.joined(separator: "\n")
        html.append("<pre class=\"code-block\"><code>\(escaped)</code></pre>")
    }
    return html.joined(separator: "\n")
}

private func inlineMarkdown(_ s: String) -> String {
    var result = htmlEscape(s)
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

private func applyInlinePattern(_ s: String, pattern: String, tag: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "<\(tag)>$1</\(tag)>")
}

private func applyInlineCode(_ s: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "`([^`]+)`") else { return s }
    let range = NSRange(s.startIndex..., in: s)
    return regex.stringByReplacingMatches(in: s, range: range, withTemplate: "<code>$1</code>")
}

private func applyLinks(_ s: String) -> String {
    guard let regex = try? NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)") else { return s }
    let ns = s as NSString
    var result = ""
    var lastEnd = 0
    let matches = regex.matches(in: s, range: NSRange(s.startIndex..., in: s))
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
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("MODE: ") {
            return String(line.dropFirst(6))
        }
    }
    return "UNKNOWN"
}

private func extractValue(from text: String, key: String) -> String? {
    for line in text.components(separatedBy: "\n") {
        if line.hasPrefix("\(key): ") {
            return String(line.dropFirst(key.count + 2))
        }
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
    if let r = reason {
        chips.append(metaChip("Reason", r))
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
    "<span class=\"meta-chip\"><span class=\"meta-label\">\(htmlEscape(label))</span><span class=\"meta-value\">\(htmlEscape(value))</span></span>"
}

private func statusClass(_ s: String) -> String {
    switch s {
    case "approved": "approved"
    case "changes_requested": "changes"
    case "awaiting_review": "awaiting"
    default: "other"
    }
}

private func statusLabel(_ s: String) -> String {
    switch s {
    case "approved": "Approved"
    case "changes_requested": "Changes Requested"
    case "awaiting_review": "Awaiting Review"
    default: s.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

private func anyToString(_ v: Any) -> String? {
    if let i = v as? Int {
        return String(i)
    }
    if let d = v as? Double {
        return String(Int(d))
    }
    if let s = v as? String {
        return s
    }
    return nil
}

private func htmlEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}

// MARK: - Page template

private func htmlPage(title: String, body: String) -> String {
    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>\(htmlEscape(title))</title>
      <style>
        *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

        :root {
          --bg: #0d1117;
          --surface: #161b22;
          --surface2: #21262d;
          --border: #30363d;
          --text: #e6edf3;
          --text-muted: #8b949e;
          --accent-blue: #58a6ff;
          --accent-green: #3fb950;
          --accent-yellow: #d29922;
          --accent-red: #f85149;
          --accent-purple: #bc8cff;
          --accent-orange: #e3b341;
          --radius: 8px;
          --radius-sm: 4px;
        }

        body {
          font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif;
          background: var(--bg);
          color: var(--text);
          line-height: 1.6;
          padding: 24px 16px 64px;
        }

        .container {
          max-width: 960px;
          margin: 0 auto;
          display: flex;
          flex-direction: column;
          gap: 20px;
        }

        /* Header card */
        .header-card {
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 24px;
        }

        .header-top {
          display: flex;
          align-items: flex-start;
          justify-content: space-between;
          gap: 16px;
          flex-wrap: wrap;
        }

        h1 {
          font-size: 1.5rem;
          font-weight: 700;
          color: var(--text);
          line-height: 1.2;
        }

        .timestamp {
          font-size: 0.8rem;
          color: var(--text-muted);
          display: block;
          margin-top: 4px;
        }

        /* Mode badge */
        .mode-badge {
          display: inline-flex;
          align-items: center;
          padding: 4px 12px;
          border-radius: 20px;
          font-size: 0.78rem;
          font-weight: 600;
          letter-spacing: 0.03em;
          white-space: nowrap;
          flex-shrink: 0;
        }
        .badge-full { background: rgba(88,166,255,0.15); color: var(--accent-blue); border: 1px solid rgba(88,166,255,0.3); }
        .badge-nochange { background: rgba(63,185,80,0.15); color: var(--accent-green); border: 1px solid rgba(63,185,80,0.3); }
        .badge-delta { background: rgba(210,153,34,0.15); color: var(--accent-yellow); border: 1px solid rgba(210,153,34,0.3); }
        .badge-unknown { background: var(--surface2); color: var(--text-muted); border: 1px solid var(--border); }

        /* Meta chips */
        .meta-row {
          display: flex;
          flex-wrap: wrap;
          gap: 8px;
          margin-top: 16px;
        }

        .meta-chip {
          display: inline-flex;
          align-items: center;
          gap: 0;
          background: var(--surface2);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          overflow: hidden;
          font-size: 0.78rem;
        }

        .meta-label {
          padding: 3px 8px;
          background: var(--border);
          color: var(--text-muted);
          font-weight: 500;
        }

        .meta-value {
          padding: 3px 8px;
          color: var(--text);
        }

        /* Recommendation card */
        .recommendation-card {
          background: linear-gradient(135deg, rgba(63,185,80,0.08), rgba(63,185,80,0.04));
          border: 1px solid rgba(63,185,80,0.3);
          border-left: 4px solid var(--accent-green);
          border-radius: var(--radius);
          padding: 20px 24px;
        }

        .rec-label {
          font-size: 0.72rem;
          font-weight: 700;
          letter-spacing: 0.08em;
          text-transform: uppercase;
          color: var(--accent-green);
          margin-bottom: 8px;
        }

        .rec-text {
          font-size: 1.05rem;
          font-weight: 500;
          color: var(--text);
        }

        /* Sections */
        .section {
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 24px;
        }

        .section h2 {
          font-size: 1rem;
          font-weight: 700;
          color: var(--text);
          margin-bottom: 16px;
          padding-bottom: 12px;
          border-bottom: 1px solid var(--border);
        }

        /* Analysis cards */
        .analysis-card {
          background: var(--surface2);
          border: 1px solid var(--border);
          border-radius: var(--radius);
          padding: 20px;
          margin-bottom: 16px;
        }

        .analysis-card:last-child { margin-bottom: 0; }

        .analysis-card h3 {
          font-size: 0.875rem;
          font-weight: 600;
          color: var(--text-muted);
          text-transform: uppercase;
          letter-spacing: 0.05em;
          margin-bottom: 14px;
        }

        .analysis-card--tier1 { border-left: 3px solid var(--accent-blue); }
        .analysis-card--tier2 { border-left: 3px solid var(--accent-purple); }
        .analysis-card--warning { border-left: 3px solid var(--accent-yellow); }

        /* MR table */
        .mr-table {
          width: 100%;
          border-collapse: collapse;
          font-size: 0.875rem;
        }

        .mr-table th {
          text-align: left;
          padding: 8px 12px;
          font-size: 0.72rem;
          font-weight: 600;
          text-transform: uppercase;
          letter-spacing: 0.05em;
          color: var(--text-muted);
          border-bottom: 1px solid var(--border);
        }

        .mr-table td {
          padding: 10px 12px;
          border-bottom: 1px solid rgba(48,54,61,0.6);
          vertical-align: top;
        }

        .mr-table tr:last-child td { border-bottom: none; }

        .mr-table tr:hover td { background: rgba(88,166,255,0.04); }

        .mr-iid { white-space: nowrap; }
        .mr-iid a { color: var(--accent-blue); text-decoration: none; font-weight: 600; }
        .mr-iid a:hover { text-decoration: underline; }

        .mr-title { max-width: 400px; }
        .mr-age { white-space: nowrap; color: var(--text-muted); text-align: right; }

        .label-row { margin-top: 4px; display: flex; flex-wrap: wrap; gap: 4px; }

        /* Status badges */
        .status-badge {
          display: inline-block;
          padding: 2px 8px;
          border-radius: 20px;
          font-size: 0.72rem;
          font-weight: 600;
          white-space: nowrap;
        }
        .status-approved { background: rgba(63,185,80,0.15); color: var(--accent-green); }
        .status-changes { background: rgba(248,81,73,0.15); color: var(--accent-red); }
        .status-awaiting { background: rgba(88,166,255,0.15); color: var(--accent-blue); }
        .status-other { background: var(--surface); color: var(--text-muted); }

        /* Label badges */
        .label-badge {
          display: inline-block;
          padding: 1px 6px;
          background: rgba(188,140,255,0.12);
          color: var(--accent-purple);
          border-radius: 3px;
          font-size: 0.68rem;
          font-weight: 500;
        }

        /* Tier badge (issues) */
        .tier-badge {
          display: inline-block;
          padding: 2px 8px;
          background: rgba(227,179,65,0.15);
          color: var(--accent-orange);
          border-radius: 20px;
          font-size: 0.72rem;
          font-weight: 700;
        }

        /* Tag list (merged branches) */
        .tag-list { list-style: none; display: flex; flex-wrap: wrap; gap: 6px; }
        .tag {
          padding: 3px 10px;
          background: var(--surface);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          font-size: 0.78rem;
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
          color: var(--text-muted);
        }

        /* Worktree list */
        .worktree-list { list-style: none; display: flex; flex-direction: column; gap: 6px; }
        .worktree-list li { font-size: 0.875rem; }

        /* Changes list */
        .changes-list { list-style: none; display: flex; flex-direction: column; gap: 6px; }
        .changes-list li {
          font-size: 0.875rem;
          padding: 8px 12px;
          background: var(--surface2);
          border: 1px solid var(--border);
          border-radius: var(--radius-sm);
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
        }

        /* Previous report */
        .previous-report {
          font-size: 0.875rem;
          color: var(--text);
          line-height: 1.7;
        }

        .previous-report h2,
        .previous-report h3,
        .previous-report h4 {
          color: var(--text);
          margin-top: 20px;
          margin-bottom: 8px;
        }

        .previous-report p { margin-bottom: 12px; }
        .previous-report ul { padding-left: 20px; margin-bottom: 12px; }
        .previous-report li { margin-bottom: 4px; }

        .previous-report code {
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
          background: var(--surface2);
          border: 1px solid var(--border);
          padding: 1px 5px;
          border-radius: 3px;
          font-size: 0.85em;
        }

        .previous-report pre.code-block {
          background: #010409;
          border: 1px solid var(--border);
          padding: 16px;
          border-radius: var(--radius);
          overflow-x: auto;
          margin: 12px 0;
        }

        .previous-report pre.code-block code {
          background: none;
          border: none;
          padding: 0;
          font-size: 0.82rem;
          color: #c9d1d9;
        }

        /* Shared */
        .muted { color: var(--text-muted); }

        a { color: var(--accent-blue); }
        a:hover { text-decoration: underline; }

        code {
          font-family: "SFMono-Regular", Consolas, "Liberation Mono", Menlo, monospace;
          background: var(--surface2);
          border: 1px solid var(--border);
          padding: 1px 5px;
          border-radius: 3px;
          font-size: 0.85em;
        }

        @media (max-width: 600px) {
          .mr-table { font-size: 0.78rem; }
          .mr-title { max-width: 200px; }
          h1 { font-size: 1.25rem; }
        }
      </style>
    </head>
    <body>
      <div class="container">
        \(body)
      </div>
    </body>
    </html>
    """
}
