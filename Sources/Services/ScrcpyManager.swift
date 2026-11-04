import Foundation
import AppKit

public final class ScrcpyManager: NSObject, @unchecked Sendable {
    public static let shared = ScrcpyManager()

    private var activeProcess: Process?
    private let processLock = NSLock()

    public private(set) var isRunning: Bool = false
    public private(set) var activeAppPackage: String? = nil

    public override init() {
        super.init()
    }

    // MARK: - Binary Path Detection
    public func getScrcpyExecutablePath() -> String? {
        // 1. App Bundle Resources
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("scrcpy/scrcpy").path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        // 2. Relative Resources in Current Application Bundle
        let execPath = Bundle.main.executablePath ?? ""
        if !execPath.isEmpty {
            let appDir = URL(fileURLWithPath: execPath).deletingLastPathComponent().deletingLastPathComponent()
            let relPath = appDir.appendingPathComponent("Resources/scrcpy/scrcpy").path
            if FileManager.default.isExecutableFile(atPath: relPath) {
                return relPath
            }
        }

        // 3. Project Source Resources (during development/direct execution)
        let sourcePath = "/Users/nathanwillems/Documents/DroidDock/DroidLink-macOS/Resources/scrcpy/scrcpy"
        if FileManager.default.isExecutableFile(atPath: sourcePath) {
            return sourcePath
        }

        // 4. System fallback
        for candidate in ["/opt/homebrew/bin/scrcpy", "/usr/local/bin/scrcpy", "/opt/local/bin/scrcpy", "/usr/bin/scrcpy"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public func getAdbExecutablePath() -> String? {
        // 1. App Bundle Resources
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("scrcpy/adb").path
            if FileManager.default.isExecutableFile(atPath: bundled) {
                return bundled
            }
        }

        let execPath = Bundle.main.executablePath ?? ""
        if !execPath.isEmpty {
            let appDir = URL(fileURLWithPath: execPath).deletingLastPathComponent().deletingLastPathComponent()
            let relPath = appDir.appendingPathComponent("Resources/scrcpy/adb").path
            if FileManager.default.isExecutableFile(atPath: relPath) {
                return relPath
            }
        }

        let sourcePath = "/Users/nathanwillems/Documents/DroidDock/DroidLink-macOS/Resources/scrcpy/adb"
        if FileManager.default.isExecutableFile(atPath: sourcePath) {
            return sourcePath
        }

        let androidSdkAdb = "\(NSHomeDirectory())/Library/Android/sdk/platform-tools/adb"
        if FileManager.default.isExecutableFile(atPath: androidSdkAdb) {
            return androidSdkAdb
        }

        for candidate in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb", "/opt/local/bin/adb", "/usr/bin/adb"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    public func getScrcpyServerPath() -> String? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundled = resourceURL.appendingPathComponent("scrcpy/scrcpy-server").path
            if FileManager.default.fileExists(atPath: bundled) {
                return bundled
            }
        }

        let execPath = Bundle.main.executablePath ?? ""
        if !execPath.isEmpty {
            let appDir = URL(fileURLWithPath: execPath).deletingLastPathComponent().deletingLastPathComponent()
            let relPath = appDir.appendingPathComponent("Resources/scrcpy/scrcpy-server").path
            if FileManager.default.fileExists(atPath: relPath) {
                return relPath
            }
        }

        let sourcePath = "/Users/nathanwillems/Documents/DroidDock/DroidLink-macOS/Resources/scrcpy/scrcpy-server"
        if FileManager.default.fileExists(atPath: sourcePath) {
            return sourcePath
        }
        return nil
    }

    // MARK: - Process Launching
    public func launchScrcpy(
        for app: InstalledApp? = nil,
        packageName: String? = nil,
        appTitle: String? = nil,
        phoneIp: String? = nil,
        completion: (@Sendable (Bool, String) -> Void)? = nil
    ) {
        guard let scrcpyPath = getScrcpyExecutablePath() else {
            completion?(false, "scrcpy binary not found in application bundle.")
            return
        }

        guard let adbPath = getAdbExecutablePath() else {
            completion?(false, "adb binary not found.")
            return
        }

        let targetPkg = packageName ?? app?.packageName
        let name = appTitle ?? app?.name

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            // 1. Ensure ADB is connected to the phone
            if let ip = phoneIp, !ip.isEmpty {
                self.connectAdb(adbPath: adbPath, ip: ip)
            }

            self.processLock.lock()
            // If already running for this exact app, bring window forward
            if let active = self.activeProcess, active.isRunning {
                print("[ScrcpyManager] Existing scrcpy session is active, terminating to switch/restart...")
                active.terminate()
                self.activeProcess = nil
            }

            let scrcpyDir = URL(fileURLWithPath: scrcpyPath).deletingLastPathComponent().path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scrcpyPath)

            var arguments: [String] = ["--stay-awake"]
            let title = name != nil ? "Droid Link — \(name!)" : "Droid Link Screen Mirror"
            arguments.append("--window-title=\(title)")

            if let pkg = targetPkg, !pkg.isEmpty {
                arguments.append("--start-app=\(pkg)")
            }

            process.arguments = arguments

            // Setup environment
            var environment = ProcessInfo.processInfo.environment
            environment["ADB"] = adbPath
            if let serverPath = self.getScrcpyServerPath() {
                environment["SCRCPY_SERVER_PATH"] = serverPath
            }
            let currentPath = environment["PATH"] ?? ""
            environment["PATH"] = "\(scrcpyDir):\(currentPath)"
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { [weak self] proc in
                self?.processLock.lock()
                self?.isRunning = false
                self?.activeAppPackage = nil
                self?.activeProcess = nil
                self?.processLock.unlock()
                print("[ScrcpyManager] scrcpy exited with code: \(proc.terminationStatus)")
            }

            do {
                try process.run()
                self.activeProcess = process
                self.isRunning = true
                self.activeAppPackage = targetPkg
                self.processLock.unlock()

                print("[ScrcpyManager] Launched scrcpy: \(arguments.joined(separator: " "))")
                completion?(true, "Screen mirroring active for \(name ?? "Phone")")
            } catch {
                self.processLock.unlock()
                print("[ScrcpyManager] Failed to launch scrcpy: \(error)")
                completion?(false, "Failed to launch scrcpy: \(error.localizedDescription)")
            }
        }
    }

    private func connectAdb(adbPath: String, ip: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = ["connect", "\(ip):5555"]
        try? process.run()
        process.waitUntilExit()
    }

    public func terminateSession() {
        processLock.lock()
        defer { processLock.unlock() }
        if let proc = activeProcess, proc.isRunning {
            proc.terminate()
            activeProcess = nil
            isRunning = false
            activeAppPackage = nil
        }
    }

    // MARK: - Audio Handoff to Mac
    private var audioHandoffProcess: Process?
    public private(set) var isAudioHandoffActive: Bool = false

    public func toggleAudioHandoff(phoneIp: String?, completion: (@Sendable (Bool, String) -> Void)? = nil) {
        if isAudioHandoffActive {
            stopAudioHandoff()
            completion?(false, "Audio handoff stopped, playing on phone")
        } else {
            startAudioHandoff(phoneIp: phoneIp, completion: completion)
        }
    }

    public func startAudioHandoff(phoneIp: String?, completion: (@Sendable (Bool, String) -> Void)? = nil) {
        guard let scrcpyPath = getScrcpyExecutablePath() else {
            completion?(false, "scrcpy binary not found.")
            return
        }
        guard let adbPath = getAdbExecutablePath() else {
            completion?(false, "adb binary not found.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            if let ip = phoneIp, !ip.isEmpty {
                self.connectAdb(adbPath: adbPath, ip: ip)
            }

            self.processLock.lock()
            if let current = self.audioHandoffProcess, current.isRunning {
                current.terminate()
                self.audioHandoffProcess = nil
            }

            let scrcpyDir = URL(fileURLWithPath: scrcpyPath).deletingLastPathComponent().path
            let process = Process()
            process.executableURL = URL(fileURLWithPath: scrcpyPath)

            // Audio only forwarder: no video window, forwards full audio output to Mac and silences phone
            process.arguments = [
                "--no-video",
                "--audio-source=output",
                "--audio-buffer=50"
            ]

            var environment = ProcessInfo.processInfo.environment
            environment["ADB"] = adbPath
            if let serverPath = self.getScrcpyServerPath() {
                environment["SCRCPY_SERVER_PATH"] = serverPath
            }
            let currentPath = environment["PATH"] ?? ""
            environment["PATH"] = "\(scrcpyDir):\(currentPath)"
            process.environment = environment

            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            process.terminationHandler = { [weak self] proc in
                self?.processLock.lock()
                self?.isAudioHandoffActive = false
                self?.audioHandoffProcess = nil
                self?.processLock.unlock()
                print("[ScrcpyManager] Audio handoff terminated (status: \(proc.terminationStatus))")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("AudioHandoffChanged"), object: nil)
                }
            }

            do {
                try process.run()
                self.audioHandoffProcess = process
                self.isAudioHandoffActive = true
                self.processLock.unlock()
                print("[ScrcpyManager] Started audio handoff to Mac")
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: NSNotification.Name("AudioHandoffChanged"), object: nil)
                }
                completion?(true, "Audio handoff active — playing on Mac")
            } catch {
                self.processLock.unlock()
                print("[ScrcpyManager] Failed to start audio handoff: \(error)")
                completion?(false, "Failed to start audio handoff: \(error.localizedDescription)")
            }
        }
    }

    public func stopAudioHandoff() {
        processLock.lock()
        if let p = audioHandoffProcess, p.isRunning {
            p.terminate()
        }
        audioHandoffProcess = nil
        isAudioHandoffActive = false
        processLock.unlock()
        print("[ScrcpyManager] Audio handoff stopped")
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: NSNotification.Name("AudioHandoffChanged"), object: nil)
        }
    }

    // MARK: - Media Controls via ADB
    public func sendMediaKey(event: String, phoneIp: String? = nil) {
        guard let adbPath = getAdbExecutablePath() else { return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            if let ip = phoneIp, !ip.isEmpty {
                self?.connectAdb(adbPath: adbPath, ip: ip)
            }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["shell", "input", "keyevent", event]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Drag-and-Drop APK Installation
    public func installApk(fileURL: URL, completion: @escaping @Sendable (Bool, String) -> Void) {
        guard let adbPath = getAdbExecutablePath() else {
            completion(false, "ADB executable not found.")
            return
        }

        guard fileURL.pathExtension.lowercased() == "apk" else {
            completion(false, "File is not an APK.")
            return
        }

        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["install", "-r", fileURL.path]

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                if output.contains("Success") {
                    completion(true, "Installed \(fileURL.lastPathComponent) successfully!")
                } else {
                    let clean = output.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(false, clean.isEmpty ? "Installation failed" : clean)
                }
            } catch {
                completion(false, "Failed to execute adb install: \(error.localizedDescription)")
            }
        }
    }
}
