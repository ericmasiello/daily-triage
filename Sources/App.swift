import Foundation

@main
struct TriageCache {
    static func main() async {
        let config = Config.fromEnvironment()
        let args = CommandLine.arguments
        let outputOptions = OutputOptions.parse(from: args)

        handleSaveReport(args: args, config: config)
        checkPrerequisites(config: config)

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
            emitFull(
                reason: "forced",
                gitlab: gitlabService,
                todoist: todoistService,
                options: outputOptions,
                config: config
            )
            exit(0)
        }

        let reason = determineReason(config: config)

        if reason != "cache_valid" {
            emitFull(
                reason: reason,
                gitlab: gitlabService,
                todoist: todoistService,
                options: outputOptions,
                config: config
            )
            exit(0)
        }

        let cache = readCache(config: config)!
        todoistService.reconcileIfNeeded(cached: cache.snapshot)
        let snapshot = assembleSnapshot(gitlab: gitlabService, todoist: todoistService)
        let diff = computeDiff(services: [gitlabService, todoistService], cache: cache, snapshot: snapshot)
        let ageMinutes = cacheAgeMinutes(cache)

        if diff.signals.contains(.priorityChange) {
            emitFull(
                reason: "priority_labels_changed",
                gitlab: gitlabService,
                todoist: todoistService,
                options: outputOptions,
                config: config
            )
        } else if diff.isEmpty {
            emit(
                formatNoChanges(ageMinutes: ageMinutes, report: cache.report, recommendation: cache.recommendation),
                options: outputOptions,
                config: config
            )
        } else {
            let recommendation = gitlabService.computeRecommendation(snapshot: snapshot)
            emit(
                formatDelta(
                    ageMinutes: ageMinutes,
                    diff: diff,
                    report: cache.report,
                    recommendation: cache.recommendation
                ),
                options: outputOptions,
                config: config
            )
            writeCache(snapshot: snapshot, recommendation: recommendation, config: config)
        }
    }
}

// MARK: - Startup helpers

private func handleSaveReport(args: [String], config: Config) {
    guard let idx = args.firstIndex(of: "--save-report") else { return }
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

private func checkPrerequisites(config: Config) {
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
}

private func emitFull(
    reason: String,
    gitlab: GitLabService,
    todoist: TodoistService,
    options: OutputOptions,
    config: Config
) {
    let snapshot = assembleSnapshot(gitlab: gitlab, todoist: todoist)
    let serviceLines = collectServiceLines([gitlab, todoist], snapshot: snapshot)
    let recommendation = gitlab.computeRecommendation(snapshot: snapshot)
    emit(
        formatFull(reason: reason, snapshot: snapshot, serviceLines: serviceLines),
        options: options,
        config: config
    )
    writeCache(snapshot: snapshot, recommendation: recommendation, config: config)
}

private func computeDiff(
    services: [any DataSourceService],
    cache: CacheEnvelope,
    snapshot: Snapshot
) -> DiffResult {
    var diff = DiffResult()
    for service in services {
        let (changes, signals) = service.diff(cached: cache.snapshot, fresh: snapshot)
        diff.changes += changes
        diff.signals += signals
    }
    return diff
}

// MARK: - Fetch helpers

private func fetchService<S: DataSourceService>(
    _ service: S,
    config: Config,
    shell: @escaping ShellRunner
) async -> (S, Error?) {
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

// MARK: - Output emission

private func emit(_ text: String, options: OutputOptions, config: Config) {
    if options.formats.contains(.md) {
        print(text)
    }
    if options.formats.contains(.html) {
        do {
            let path = try writeHTMLReport(text, config: config)
            fputs("HTML report: \(path)\n", stderr)
            if options.autoOpen == .html {
                openHTML(path: path)
            }
        } catch {
            fputs("Warning: failed to write HTML report — \(error)\n", stderr)
        }
    }
}
