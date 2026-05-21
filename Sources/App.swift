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

        let runShell: ShellRunner = { command, dir in try shell(command, workingDirectory: dir) }

        func fetchOrDie() async -> (GitLabService, TodoistFetchResult) {
            var service = GitLabService()
            do {
                try await service.fetch(config: config, shell: runShell)
            } catch {
                fputs("Error: all data sources failed. Check glab authentication (glab auth status).\n", stderr)
                if case GitLabFetchError.tooManyFailures(let errors) = error {
                    for e in errors { fputs("  - \(e)\n", stderr) }
                } else {
                    fputs("  - \(error)\n", stderr)
                }
                exit(1)
            }
            let todoistResult = await fetchTodoistData(config: config, shell: runShell)
            return (service, todoistResult)
        }

        func buildSnapshot(service: GitLabService, todoist: TodoistFetchResult) -> Snapshot {
            guard let state = service.fetchedState else {
                fputs("Error: GitLab fetch did not produce a state\n", stderr)
                exit(1)
            }
            return Snapshot(gitlab: state, todoist: todoist.snapshot, todoistError: todoist.error)
        }

        let forceMode = args.contains("--force")

        if forceMode {
            let (service, todoistResult) = await fetchOrDie()
            let snapshot = buildSnapshot(service: service, todoist: todoistResult)
            let analysisLines = service.format(snapshot)
            print(formatFull(reason: "forced", snapshot: snapshot, analysisLines: analysisLines))
            writeCache(snapshot: snapshot, config: config)
            exit(0)
        }

        let reason = determineReason(config: config)

        if reason != "cache_valid" {
            let (service, todoistResult) = await fetchOrDie()
            let snapshot = buildSnapshot(service: service, todoist: todoistResult)
            let analysisLines = service.format(snapshot)
            print(formatFull(reason: reason, snapshot: snapshot, analysisLines: analysisLines))
            writeCache(snapshot: snapshot, config: config)
            exit(0)
        }

        let cache = readCache(config: config)!
        let (service, todoistResult) = await fetchOrDie()
        let snapshot = buildSnapshot(service: service, todoist: todoistResult)

        let effectiveSnapshot = reconcileSnapshot(cached: cache.snapshot, fresh: snapshot)

        let (gitlabChanges, gitlabSignals) = service.diff(cached: cache.snapshot, fresh: effectiveSnapshot)
        let todoistChanges = diffTodoist(cached: cache.snapshot.todoist, fresh: effectiveSnapshot.todoist)

        var diff = DiffResult()
        diff.changes = gitlabChanges + todoistChanges
        diff.signals = gitlabSignals

        let ageMinutes = cacheAgeMinutes(cache)

        if diff.signals.contains(.priorityChange) {
            let analysisLines = service.format(effectiveSnapshot)
            print(formatFull(reason: "priority_labels_changed", snapshot: effectiveSnapshot, analysisLines: analysisLines))
            writeCache(snapshot: effectiveSnapshot, config: config)
        } else if diff.isEmpty {
            print(formatNoChanges(ageMinutes: ageMinutes, report: cache.report, recommendation: cache.recommendation))
        } else {
            print(formatDelta(ageMinutes: ageMinutes, diff: diff, report: cache.report, recommendation: cache.recommendation))
            writeCache(snapshot: effectiveSnapshot, config: config)
        }
    }
}
