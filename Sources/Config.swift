import Foundation

struct Config {
    let cacheDir: String
    let cachePath: String
    let studioDir: String
    let ttlSeconds: TimeInterval
    let triageAuthor: String
    let todayDate: String

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
            if let d = ProcessInfo.processInfo.environment["TRIAGE_TODAY"] {
                return d
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.timeZone = TimeZone.current
            return formatter.string(from: Date())
        }()

        return Config(
            cacheDir: cacheDir,
            cachePath: (cacheDir as NSString).appendingPathComponent("last-run.json"),
            studioDir: studioDir,
            ttlSeconds: 3600,
            triageAuthor: ProcessInfo.processInfo.environment["TRIAGE_AUTHOR"] ?? "ericmasiello",
            todayDate: todayDate
        )
    }
}

typealias ShellRunner = @Sendable (_ command: String, _ workingDirectory: String?) throws -> String
