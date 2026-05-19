import Foundation

struct Config {
    let cacheDir: String
    let cachePath: String
    let studioDir: String
    let ttlSeconds: TimeInterval
    let triageAuthor: String

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

        return Config(
            cacheDir: cacheDir,
            cachePath: (cacheDir as NSString).appendingPathComponent("last-run.json"),
            studioDir: studioDir,
            ttlSeconds: 3600,
            triageAuthor: ProcessInfo.processInfo.environment["TRIAGE_AUTHOR"] ?? "ericmasiello"
        )
    }
}

typealias ShellRunner = (_ command: String, _ workingDirectory: String?) throws -> String
