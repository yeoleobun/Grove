import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool {
        exitCode == 0
    }
}

public enum ShellRunner {
    private static let defaultSearchPaths: [String] = [
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.cargo/bin",
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    private static let executableCacheLock = NSLock()
    nonisolated(unsafe) private static var resolvedExecutableCache: [String: String] = [:]

    public static func resolveExecutable(_ name: String) -> String? {
        if name.contains("/") {
            return FileManager.default.isExecutableFile(atPath: name) ? name : nil
        }

        executableCacheLock.lock()
        if let cached = resolvedExecutableCache[name] {
            executableCacheLock.unlock()
            return cached
        }
        executableCacheLock.unlock()

        let envPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        for dir in defaultSearchPaths + envPaths {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                executableCacheLock.lock()
                resolvedExecutableCache[name] = candidate
                executableCacheLock.unlock()
                return candidate
            }
        }
        return nil
    }

    /// Runs a child process and drains `stdout` + `stderr` concurrently on the calling thread via POSIX `poll()`.
    /// Uses zero extra threads or GCD queues so it can never starve or deadlock Swift's cooperative thread pool,
    /// while simultaneously draining both pipes so large output can never fill pipe buffers.
    public static func run(
        executable: String,
        arguments: [String],
        currentDirectory: String? = nil
    ) throws -> CommandResult {
        guard let execPath = resolveExecutable(executable) else {
            throw NSError(
                domain: "Grove.ShellRunner",
                code: 127,
                userInfo: [NSLocalizedDescriptionKey: "Executable '\(executable)' was not found."]
            )
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: execPath)
        process.arguments = arguments
        if let currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: currentDirectory)
        }

        var env = ProcessInfo.processInfo.environment
        let combinedPath = (defaultSearchPaths + [env["PATH"] ?? ""])
            .filter { !$0.isEmpty }
            .joined(separator: ":")
        env["PATH"] = combinedPath
        // Prevent git from hanging on interactive prompts
        env["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = env

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let outFD = stdoutPipe.fileHandleForReading.fileDescriptor
        let errFD = stderrPipe.fileHandleForReading.fileDescriptor
        var stdoutData = Data()
        var stderrData = Data()
        var outOpen = true
        var errOpen = true
        var buffer = [UInt8](repeating: 0, count: 16_384)

        while outOpen || errOpen {
            var fds: [pollfd] = []
            if outOpen {
                fds.append(pollfd(fd: outFD, events: Int16(POLLIN), revents: 0))
            }
            if errOpen {
                fds.append(pollfd(fd: errFD, events: Int16(POLLIN), revents: 0))
            }

            let ready = fds.withUnsafeMutableBufferPointer { buf in
                Darwin.poll(buf.baseAddress, nfds_t(buf.count), -1)
            }
            if ready < 0 {
                if errno == EINTR {
                    continue
                }
                break
            }

            for pfd in fds where pfd.revents != 0 {
                if (pfd.revents & Int16(POLLNVAL)) != 0 {
                    if pfd.fd == outFD {
                        outOpen = false
                    } else {
                        errOpen = false
                    }
                    continue
                }

                let bytesRead = buffer.withUnsafeMutableBytes { rawBuf in
                    Darwin.read(pfd.fd, rawBuf.baseAddress, rawBuf.count)
                }

                if bytesRead > 0 {
                    if pfd.fd == outFD {
                        stdoutData.append(buffer, count: bytesRead)
                    } else {
                        stderrData.append(buffer, count: bytesRead)
                    }
                } else if bytesRead == 0 || (bytesRead < 0 && errno != EINTR && errno != EAGAIN) {
                    if pfd.fd == outFD {
                        outOpen = false
                    } else {
                        errOpen = false
                    }
                }
            }
        }

        process.waitUntilExit()

        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        return CommandResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}
