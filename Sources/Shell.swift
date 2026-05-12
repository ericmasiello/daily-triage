import Foundation

/// Runs a bash command, captures stdout, suppresses stderr.
/// Returns the trimmed stdout and the process exit code.
func shell(_ command: String, workingDirectory: String? = nil) -> (output: String, exitCode: Int32) {
    let process = Process()
    let outPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardOutput = outPipe
    process.standardError = FileHandle(forWritingAtPath: "/dev/null")

    if let dir = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
    }

    do {
        try process.run()
    } catch {
        return ("", 1)
    }

    let data = outPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    return (String(data: data, encoding: .utf8) ?? "", process.terminationStatus)
}
