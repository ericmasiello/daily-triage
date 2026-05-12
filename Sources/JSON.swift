import Foundation

/// Parse a JSON string as an array of dictionaries. Returns empty array on failure.
func parseJSONArray(_ string: String) -> [[String: Any]] {
    guard !string.isEmpty,
          let data = string.data(using: .utf8),
          let parsed = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        return []
    }
    return parsed
}
