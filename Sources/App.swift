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
        let fetchResult = await fetchAllServices(config: config, shell: runShell)

        if let error = fetchResult.gitlabError, fetchResult.services.gitlab.failurePolicy == .fatal {
            fputs("Error: \(fetchResult.services.gitlab.label) service failed — \(error)\n", stderr)
            exit(1)
        }

        var services = fetchResult.services

        // Jira is .degradable like Todoist, but with one difference: it now drives the
        // triage recommendation, so a failure with nothing cached to fall back to is
        // treated as fatal rather than silently recommending against an empty issue set.
        if let error = services.jira.fetchError {
            reconcileJiraOrExit(&services.jira, error: error, config: config)
        }

        let forceMode = args.contains("--force")

        if forceMode {
            emitFull(reason: "forced", services: services, options: outputOptions, config: config)
            exit(0)
        }

        let reason = determineReason(config: config)

        if reason != "cache_valid" {
            emitFull(reason: reason, services: services, options: outputOptions, config: config)
            exit(0)
        }

        let cache = readCache(config: config)!
        services.todoist.reconcileIfNeeded(cached: cache.snapshot)
        let snapshot = assembleSnapshot(services: services)
        let allServices: [any DataSourceService] = [services.gitlab, services.todoist, services.jira]
        let diff = computeDiff(services: allServices, cache: cache, snapshot: snapshot)
        let ageMinutes = cacheAgeMinutes(cache)

        if diff.signals.contains(.priorityChange) {
            emitFull(reason: "priority_labels_changed", services: services, options: outputOptions, config: config)
        } else if diff.isEmpty {
            emit(
                formatNoChanges(ageMinutes: ageMinutes, report: cache.report, recommendation: cache.recommendation),
                options: outputOptions,
                config: config
            )
        } else {
            let analysis = computeAnalysis(snapshot: snapshot, todayDate: config.todayDate)
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
            writeCache(snapshot: snapshot, recommendation: analysis.recommendation, config: config)
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

/// The three data sources bundled together purely to keep call sites (emitFull,
/// assembleSnapshot) under the parameter-count lint limit — not a meaningful domain type.
private struct Services {
    var gitlab: GitLabService
    var todoist: TodoistService
    var jira: JiraService
}

private struct FetchResult {
    var services: Services
    var gitlabError: Error?
}

private func fetchAllServices(config: Config, shell: @escaping ShellRunner) async -> FetchResult {
    async let glResult = fetchService(GitLabService(), config: config, shell: shell)
    async let tdResult = fetchService(TodoistService(), config: config, shell: shell)
    async let jiResult = fetchService(JiraService(), config: config, shell: shell)

    let (gitlabService, gitlabError) = await glResult
    let (todoistService, _) = await tdResult
    // Jira never actually throws from fetch() (see JiraService) — its failure is carried
    // in `fetchError`, not this discarded tuple slot.
    let (jiraService, _) = await jiResult

    return FetchResult(
        services: Services(gitlab: gitlabService, todoist: todoistService, jira: jiraService),
        gitlabError: gitlabError
    )
}

private func reconcileJiraOrExit(_ jira: inout JiraService, error: String, config: Config) {
    let existingCache = readCache(config: config)
    if !jira.reconcileIfNeeded(cached: existingCache?.snapshot) {
        fputs("Error: Jira fetch failed and no cached Jira data is available — \(error)\n", stderr)
        fputs("  Check that 'acli' is installed and authenticated.\n", stderr)
        exit(1)
    }
}

private func emitFull(reason: String, services: Services, options: OutputOptions, config: Config) {
    let snapshot = assembleSnapshot(services: services)
    let serviceLines = collectServiceLines(
        [services.gitlab, services.todoist, services.jira],
        snapshot: snapshot
    )
    let analysis = computeAnalysis(snapshot: snapshot, todayDate: config.todayDate)
    emit(
        formatFull(reason: reason, snapshot: snapshot, serviceLines: serviceLines + formatAnalysis(analysis)),
        options: options,
        config: config
    )
    writeCache(snapshot: snapshot, recommendation: analysis.recommendation, config: config)
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

private func assembleSnapshot(services: Services) -> Snapshot {
    guard let state = services.gitlab.fetchedState else {
        fputs("Error: GitLab fetch did not produce a state\n", stderr)
        exit(1)
    }
    return Snapshot(
        gitlab: state,
        todoist: services.todoist.fetchedState,
        todoistError: services.todoist.fetchError,
        jira: services.jira.fetchedState,
        jiraError: services.jira.fetchError
    )
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
