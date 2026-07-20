import Foundation

// MARK: - Archive filtering

/// GitLab Project API shape, used only to check archive status.
/// See: GET /projects/:id — https://docs.gitlab.com/ee/api/projects.html
private struct RawProject: Decodable {
    let pathWithNamespace: String
    let archived: Bool?
}

private func decodeProject(_ string: String) -> RawProject? {
    guard !string.isEmpty, let data = string.data(using: .utf8) else { return nil }
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return try? decoder.decode(RawProject.self, from: data)
}

/// Repo paths (lowercased) referenced by any of the given MR lists, for archive-status lookup.
/// Only MRs fetched via the instance-level API carry a `repoPath` (see `mapRawMR` in
/// GitLabService.swift); local studio MRs have a nil `repoPath` and are never checked.
func collectRepoPaths(_ mrGroups: [MR]...) -> Set<String> {
    var paths = Set<String>()
    for group in mrGroups {
        for mr in group {
            if let repoPath = mr.repoPath {
                paths.insert(repoPath.lowercased())
            }
        }
    }
    return paths
}

/// Checks archive status for each referenced repo path via a targeted `projects/:id` lookup —
/// one concurrent request per unique repo actually seen in this run's MRs, not an instance-wide
/// list. A failed lookup is non-fatal: that repo is treated as not archived, so its MRs are kept
/// rather than dropped on an unverifiable check.
func fetchArchivedRepoPaths(
    _ repoPaths: Set<String>,
    shell: @escaping ShellRunner
) async -> Set<String> {
    guard !repoPaths.isEmpty else { return [] }

    return await withTaskGroup(of: (repoPath: String, archived: Bool)?.self) { group in
        for repoPath in repoPaths {
            group.addTask {
                let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "/"))
                guard let encodedPath = repoPath.addingPercentEncoding(withAllowedCharacters: allowed) else {
                    return nil
                }
                do {
                    let out = try shell("glab api \"projects/\(encodedPath)\"", nil)
                    guard let project = decodeProject(out) else { return nil }
                    return (repoPath: repoPath, archived: project.archived ?? false)
                } catch {
                    fputs("Warning: failed to check archive status for \(repoPath) — \(error)\n", stderr)
                    return nil
                }
            }
        }

        var archived = Set<String>()
        for await result in group {
            if let result, result.archived {
                archived.insert(result.repoPath)
            }
        }
        return archived
    }
}

/// Drops MRs whose repo is archived. MRs with a nil `repoPath` (the local studio repo) are
/// always kept — the studio repo is never archived and doesn't go through this check.
func filterArchivedMRs(_ mrs: [MR], archivedRepoPaths: Set<String>) -> [MR] {
    mrs.filter { mr in
        guard let repoPath = mr.repoPath else { return true }
        return !archivedRepoPaths.contains(repoPath.lowercased())
    }
}
