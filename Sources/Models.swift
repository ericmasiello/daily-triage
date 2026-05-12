import Foundation

/// Extract the fields needed for triage from MR JSON objects.
func extractMRFields(_ mrs: [[String: Any]]) -> [[String: Any]] {
    mrs.map { mr in
        var result: [String: Any] = [:]
        for key in ["iid", "title", "draft", "source_branch", "created_at", "updated_at",
                     "web_url", "labels", "detailed_merge_status", "user_notes_count", "has_conflicts"] {
            if let val = mr[key] { result[key] = val }
        }
        // Flatten reviewers to username strings
        if let reviewers = mr["reviewers"] as? [[String: Any]] {
            result["reviewer_usernames"] = reviewers.compactMap { $0["username"] as? String }
        }
        return result
    }
}

/// Extract issue fields, truncating descriptions to 500 chars.
func extractIssueFields(_ issues: [[String: Any]]) -> [[String: Any]] {
    issues.map { issue in
        var result: [String: Any] = [:]
        for key in ["iid", "title", "labels", "created_at", "web_url"] {
            if let val = issue[key] { result[key] = val }
        }
        let desc = (issue["description"] as? String) ?? ""
        result["description"] = String(desc.prefix(500))
        return result
    }
}
