import Foundation

enum ShellError: Error, CustomStringConvertible {
    case nonZeroExit(code: Int32, stderr: String)

    var description: String {
        switch self {
        case let .nonZeroExit(code, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "exit code \(code)" : detail
        }
    }
}

func shell(_ command: String, workingDirectory: String? = nil) throws -> String {
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

    try process.run()

    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()

    let stdout = String(data: outData, encoding: .utf8) ?? ""
    let stderr = String(data: errData, encoding: .utf8) ?? ""

    guard process.terminationStatus == 0 else {
        throw ShellError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
    }

    return stdout
}
