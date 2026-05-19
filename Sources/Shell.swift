import Foundation

/// Runs a bash command, captures both stdout and stderr.
/// Returns the trimmed stdout, stderr, and the process exit code.
func shell(_ command: String, workingDirectory: String? = nil) -> (output: String, stderr: String, exitCode: Int32) {
    let process = Process()
    let outPipe = Pipe()
    let errPipe = Pipe()

    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    process.standardOutput = outPipe
    process.standardError = errPipe

    if let dir = workingDirectory {
        process.currentDirectoryURL = URL(fileURLWithPath: dir)
    }

    do {
        try process.run()
    } catch {
        return ("", "", 1)
    }

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let stdout = String(data: outData, encoding: .utf8) ?? ""
    let stderr = String(data: errData, encoding: .utf8) ?? ""
    return (stdout, stderr, process.terminationStatus)
}
