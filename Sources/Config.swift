import Foundation

// MARK: - Output format selection

enum OutputFormat: String, CaseIterable {
    case md
    case html
}

/// Parsed from --format md,html (default: md only)
struct OutputOptions {
    var formats: Set<OutputFormat>
    /// Which format to auto-open after writing, if any
    var autoOpen: OutputFormat?

    /// Parse from CommandLine.arguments.
    /// --format md            → markdown only (stdout)
    /// --format html          → HTML only (file)
    /// --format md,html       → both
    /// --open html            → open the HTML file after writing
    static func parse(from args: [String]) -> OutputOptions {
        var formats: Set<OutputFormat> = [.md]
        var autoOpen: OutputFormat?

        if let formatFlagIndex = args.firstIndex(of: "--format"), formatFlagIndex + 1 < args.count {
            let rawFormats = args[formatFlagIndex + 1].split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
            let parsed = rawFormats.compactMap { OutputFormat(rawValue: $0.lowercased()) }
            if !parsed.isEmpty {
                formats = Set(parsed)
            }
        }

        if let openFlagIndex = args.firstIndex(of: "--open"), openFlagIndex + 1 < args.count {
            let rawFormat = args[openFlagIndex + 1].trimmingCharacters(in: .whitespaces).lowercased()
            if let fmt = OutputFormat(rawValue: rawFormat), formats.contains(fmt) {
                autoOpen = fmt
            }
        }

        return OutputOptions(formats: formats, autoOpen: autoOpen)
    }
}

struct Config {
    let cacheDir: String
    let cachePath: String
    let htmlPath: String
    let studioDir: String
    let ttlSeconds: TimeInterval
    let triageAuthor: String
    let todayDate: String
    let jiraProject: String
    let jiraSite: String

    static func fromEnvironment() -> Config {
        let cacheDir: String = {
            if let dir = ProcessInfo.processInfo.environment["TRIAGE_CACHE_DIR"] {
                return dir
            }
            return (NSHomeDirectory() as NSString).appendingPathComponent(".cache/eric-triage")
        }()

        let studioDir: String = {
            if let dir = ProcessInfo.processInfo.environment["TRIAGE_STUDIO_DIR"] {
                return dir
            }
            return (NSHomeDirectory() as NSString).appendingPathComponent("Sites/studio")
        }()

        let todayDate: String = {
            if let dateOverride = ProcessInfo.processInfo.environment["TRIAGE_TODAY"] {
                return dateOverride
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            return formatter.string(from: Date())
        }()

        return Config(
            cacheDir: cacheDir,
            cachePath: (cacheDir as NSString).appendingPathComponent("last-run.json"),
            htmlPath: (cacheDir as NSString).appendingPathComponent("report.html"),
            studioDir: studioDir,
            ttlSeconds: 3600,
            triageAuthor: ProcessInfo.processInfo.environment["TRIAGE_AUTHOR"] ?? "ericmasiello",
            todayDate: todayDate,
            jiraProject: ProcessInfo.processInfo.environment["TRIAGE_JIRA_PROJECT"] ?? "ERICRULEZ",
            jiraSite: ProcessInfo.processInfo.environment["TRIAGE_JIRA_SITE"] ?? "https://vistaprint.atlassian.net"
        )
    }
}

typealias ShellRunner = @Sendable (_ command: String, _ workingDirectory: String?) throws -> String
