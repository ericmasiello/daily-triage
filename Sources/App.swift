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

        async let glResult = fetchService(GitLabService(), config: config, shell: runShell)
        async let tdResult = fetchService(TodoistService(), config: config, shell: runShell)

        let (gitlabService, gitlabError) = await glResult
        var (todoistService, _) = await tdResult

        if let error = gitlabError, gitlabService.failurePolicy == .fatal {
            fputs("Error: \(gitlabService.label) service failed — \(error)\n", stderr)
            exit(1)
        }

        let forceMode = args.contains("--force")

        if forceMode {
            let snapshot = assembleSnapshot(gitlab: gitlabService, todoist: todoistService)
            let serviceLines = collectServiceLines([gitlabService, todoistService], snapshot: snapshot)
            print(formatFull(reason: "forced", snapshot: snapshot, serviceLines: serviceLines))
            writeCache(snapshot: snapshot, config: config)
            exit(0)
        }

        let reason = determineReason(config: config)

        if reason != "cache_valid" {
            let snapshot = assembleSnapshot(gitlab: gitlabService, todoist: todoistService)
            let serviceLines = collectServiceLines([gitlabService, todoistService], snapshot: snapshot)
            print(formatFull(reason: reason, snapshot: snapshot, serviceLines: serviceLines))
            writeCache(snapshot: snapshot, config: config)
            exit(0)
        }

        let cache = readCache(config: config)!

        todoistService.reconcileIfNeeded(cached: cache.snapshot)

        let snapshot = assembleSnapshot(gitlab: gitlabService, todoist: todoistService)

        let services: [any DataSourceService] = [gitlabService, todoistService]
        var diff = DiffResult()
        for service in services {
            let (changes, signals) = service.diff(cached: cache.snapshot, fresh: snapshot)
            diff.changes += changes
            diff.signals += signals
        }

        let ageMinutes = cacheAgeMinutes(cache)

        if diff.signals.contains(.priorityChange) {
            let serviceLines = collectServiceLines(services, snapshot: snapshot)
            print(formatFull(reason: "priority_labels_changed", snapshot: snapshot, serviceLines: serviceLines))
            writeCache(snapshot: snapshot, config: config)
        } else if diff.isEmpty {
            print(formatNoChanges(ageMinutes: ageMinutes, report: cache.report, recommendation: cache.recommendation))
        } else {
            print(formatDelta(ageMinutes: ageMinutes, diff: diff, report: cache.report, recommendation: cache.recommendation))
            writeCache(snapshot: snapshot, config: config)
        }
    }
}

// MARK: - Fetch helpers

private func fetchService<S: DataSourceService>(_ service: S, config: Config, shell: @escaping ShellRunner) async -> (S, Error?) {
    var svc = service
    do {
        try await svc.fetch(config: config, shell: shell)
        return (svc, nil)
    } catch {
        return (svc, error)
    }
}

// MARK: - Snapshot assembly

private func assembleSnapshot(gitlab: GitLabService, todoist: TodoistService) -> Snapshot {
    guard let state = gitlab.fetchedState else {
        fputs("Error: GitLab fetch did not produce a state\n", stderr)
        exit(1)
    }
    return Snapshot(gitlab: state, todoist: todoist.fetchedState, todoistError: todoist.fetchError)
}

// MARK: - Service output collection

private func collectServiceLines(_ services: [any DataSourceService], snapshot: Snapshot) -> [String] {
    services.flatMap { $0.format(snapshot) }
}
