import Foundation

@main
struct TriageCache {
    static func main() async {
        let config = Config.fromEnvironment()
        let args = CommandLine.arguments

        if let idx = args.firstIndex(of: "--save-report") {
            guard idx + 1 < args.count else {
                fputs("Usage: triage-cache --save-report \"<markdown>\"\n", stderr)
                exit(1)
            }
            do {
                try saveReport(args[idx + 1], config: config)
            } catch {
                fputs("Error: \(error)\n", stderr)
                exit(1)
            }
            exit(0)
        }

        do {
            _ = try shell("which glab")
        } catch {
            fputs("Error: glab CLI not found. Install: brew install glab\n", stderr)
            exit(1)
        }

        do {
            _ = try shell("glab auth status")
        } catch {
            fputs("Error: glab authentication expired or invalid. Run: glab auth login\n", stderr)
            fputs("  \(error)\n", stderr)
            exit(1)
        }

        guard FileManager.default.fileExists(atPath: config.studioDir) else {
            fputs("Error: \(config.studioDir) not found\n", stderr)
            exit(1)
        }

        func fetchOrDie() async -> (Snapshot, [Int: String], [Issue]) {
            switch await fetchAllData(config: config) {
            case .success(let snapshot, let issueDescriptions, let allIssues):
                return (snapshot, issueDescriptions, allIssues)
            case .failure(let errors):
                fputs("Error: all data sources failed. Check glab authentication (glab auth status).\n", stderr)
                for e in errors { fputs("  - \(e)\n", stderr) }
                exit(1)
            }
        }

        let forceMode = args.contains("--force")

        if forceMode {
            let (snapshot, descriptions, allIssues) = await fetchOrDie()
            let analysis = computeAnalysis(snapshot: snapshot, issueDescriptions: descriptions, allIssues: allIssues)
            print(formatFull(reason: "forced", snapshot: snapshot, analysis: analysis))
            writeCache(snapshot: snapshot, config: config)
            exit(0)
        }

        let reason = determineReason(config: config)

        if reason != "cache_valid" {
            let (snapshot, descriptions, allIssues) = await fetchOrDie()
            let analysis = computeAnalysis(snapshot: snapshot, issueDescriptions: descriptions, allIssues: allIssues)
            print(formatFull(reason: reason, snapshot: snapshot, analysis: analysis))
            writeCache(snapshot: snapshot, config: config)
            exit(0)
        }

        let cache = readCache(config: config)!
        let (snapshot, descriptions, allIssues) = await fetchOrDie()

        let effectiveSnapshot = reconcileSnapshot(cached: cache.snapshot, fresh: snapshot)

        let diff = computeDiff(cached: cache.snapshot, fresh: effectiveSnapshot)
        let ageMinutes = cacheAgeMinutes(cache)

        if diff.hasPriorityLabelChange {
            let analysis = computeAnalysis(snapshot: effectiveSnapshot, issueDescriptions: descriptions, allIssues: allIssues)
            print(formatFull(reason: "priority_labels_changed", snapshot: effectiveSnapshot, analysis: analysis))
            writeCache(snapshot: effectiveSnapshot, config: config)
        } else if diff.isEmpty {
            print(formatNoChanges(ageMinutes: ageMinutes, report: cache.report, recommendation: cache.recommendation))
        } else {
            print(formatDelta(ageMinutes: ageMinutes, diff: diff, report: cache.report, recommendation: cache.recommendation))
            writeCache(snapshot: effectiveSnapshot, config: config)
        }
    }
}
