import Foundation
import AppKit

public final class ScrcpyManager: NSObject, @unchecked Sendable {
    public static let shared = ScrcpyManager()

    private var activeProcess: Process?
    private let processLock = NSLock()
    private let launchQueue = DispatchQueue(label: "DroidLink.scrcpy.launch", qos: .userInitiated)

    public private(set) var isRunning: Bool = false
    public private(set) var activeAppPackage: String? = nil

    public override init() {
        super.init()
    }

    private var developmentResources: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/scrcpy")
    }

    // Drain both streams while the child runs: unread pipes eventually block scrcpy.
    private func captureOutput(of process: Process) {
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        for pipe in [output, error] {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                } else if let message = String(data: data, encoding: .utf8) {
                    print("[ScrcpyManager] \(message.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }
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
        let sourcePath = developmentResources.appendingPathComponent("scrcpy").path
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

        let sourcePath = developmentResources.appendingPathComponent("adb").path
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

        let sourcePath = developmentResources.appendingPathComponent("scrcpy-server").path
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
        turnScreenOff: Bool = false,
        desktop: DesktopDisplayConfiguration? = nil,
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

        launchQueue.async { [weak self] in
            guard let self = self else { return }

            // 1. Ensure ADB is connected to the phone
            guard let serial = self.selectAdbDevice(adbPath: adbPath, host: phoneIp) else {
                completion?(false, "No authorized ADB device found over USB or Wi-Fi.")
                return
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
            if turnScreenOff { arguments.append("--turn-screen-off") }
            if let desktop { arguments += desktop.arguments }
            let title = desktop != nil ? "Droid Link — Android Desktop" : (name != nil ? "Droid Link — \(name!)" : "Droid Link Screen Mirror")
            arguments.append("--window-title=\(title)")

            if let pkg = targetPkg, !pkg.isEmpty {
                arguments.append("--start-app=\(pkg)")
            }

            arguments.append("--serial=\(serial)")
            process.arguments = arguments

            // Setup environment
            var environment = ProcessInfo.processInfo.environment
            environment["ADB"] = adbPath
            // Keep the SDL helper from promoting itself to a separate Dock app.
            environment["SDL_MAC_BACKGROUND_APP"] = "1"
            // Borderless fullscreen desktop in its own macOS Space, with no exclusive display-mode switch.
            environment["SDL_VIDEO_MAC_FULLSCREEN_SPACES"] = "1"
            if desktop?.fullScreen == true { environment["SDL_VIDEO_MAC_FULLSCREEN_MENU_VISIBILITY"] = "0" }
            if let serverPath = self.getScrcpyServerPath() {
                environment["SCRCPY_SERVER_PATH"] = serverPath
            }
            let currentPath = environment["PATH"] ?? ""
            environment["PATH"] = "\(scrcpyDir):\(currentPath)"
            process.environment = environment

            self.captureOutput(of: process)

            process.terminationHandler = { [weak self] proc in
                guard let self else { return }
                self.processLock.lock()
                let isCurrent = self.activeProcess === proc
                if isCurrent {
                    self.isRunning = false
                    self.activeAppPackage = nil
                    self.activeProcess = nil
                }
                self.processLock.unlock()
                if isCurrent && proc.terminationReason == .exit && proc.terminationStatus != 0 {
                    completion?(false, "Screen mirroring stopped (exit \(proc.terminationStatus)). Check that USB debugging is enabled and this Mac is authorized in Android's debugging settings.")
                }
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

    static func wirelessEndpoint(in services: String, host: String) -> String? {
        services.split(whereSeparator: \.isNewline).compactMap { line -> String? in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[1] == "_adb-tls-connect._tcp",
                  fields[2].hasPrefix("\(host):") else { return nil }
            return String(fields[2])
        }.first
    }

    private func adbOutput(_ adbPath: String, _ arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: adbPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? String(decoding: data, as: UTF8.self) : ""
        } catch {
            print("[ScrcpyManager] ADB command failed: \(error.localizedDescription)")
            return ""
        }
    }

    private func selectAdbDevice(adbPath: String, host: String?) -> String? {
        Self.selectAdbDevice(host: host) { adbOutput(adbPath, $0) }
    }

    static func selectAdbDevice(host: String?, run: ([String]) -> String) -> String? {
        func authorizedDevices() -> [[Substring]] {
            run(["devices", "-l"]).split(whereSeparator: \.isNewline)
                .map { $0.split(whereSeparator: \.isWhitespace) }
                .filter { $0.count >= 2 && $0[1] == "device" }
        }

        let devices = authorizedDevices()
        let usb = devices.filter { $0.dropFirst(2).contains { $0.hasPrefix("usb:") } }
        if usb.count == 1 { return String(usb[0][0]) }

        let services = run(["mdns", "services"])
        var endpointsByService: [String: String] = [:]
        for line in services.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count == 3, fields[1] == "_adb-tls-connect._tcp" else { continue }
            endpointsByService["\(fields[0]).\(fields[1])"] = String(fields[2])
        }

        let serials = devices.map { String($0[0]) }
        guard let host, !host.isEmpty else {
            // ADB can list both an mDNS name and an IP for the same wireless connection.
            let endpoints = Set(serials.map { endpointsByService[$0] ?? $0 })
            return endpoints.count == 1 ? serials.first : nil
        }

        let endpoint = Self.wirelessEndpoint(in: services, host: host) ?? "\(host):5555"
        if let serial = serials.first(where: { (endpointsByService[$0] ?? $0).hasPrefix("\(host):") }) {
            return serial
        }

        _ = run(["connect", endpoint])
        return authorizedDevices().contains { $0[0] == endpoint } ? endpoint : nil
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
            guard let serial = self.selectAdbDevice(adbPath: adbPath, host: phoneIp) else {
                completion?(false, "No authorized ADB device found over USB or Wi-Fi.")
                return
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
            process.arguments?.append("--serial=\(serial)")

            var environment = ProcessInfo.processInfo.environment
            environment["ADB"] = adbPath
            // Keep the SDL helper from promoting itself to a separate Dock app.
            environment["SDL_MAC_BACKGROUND_APP"] = "1"
            // Borderless fullscreen desktop in its own macOS Space, with no exclusive display-mode switch.
            environment["SDL_VIDEO_MAC_FULLSCREEN_SPACES"] = "1"
            if let serverPath = self.getScrcpyServerPath() {
                environment["SCRCPY_SERVER_PATH"] = serverPath
            }
            let currentPath = environment["PATH"] ?? ""
            environment["PATH"] = "\(scrcpyDir):\(currentPath)"
            process.environment = environment

            self.captureOutput(of: process)

            process.terminationHandler = { [weak self] proc in
                guard let self else { return }
                self.processLock.lock()
                let isCurrent = self.audioHandoffProcess === proc
                if isCurrent {
                    self.isAudioHandoffActive = false
                    self.audioHandoffProcess = nil
                }
                self.processLock.unlock()
                guard isCurrent else { return }
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
            guard let serial = self?.selectAdbDevice(adbPath: adbPath, host: phoneIp) else { return }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: adbPath)
            process.arguments = ["-s", serial, "shell", "input", "keyevent", event]
            try? process.run()
            process.waitUntilExit()
        }
    }

    // MARK: - Drag-and-Drop APK Installation
    public func installApk(fileURL: URL, phoneIp: String? = nil, completion: @escaping @Sendable (Bool, String) -> Void) {
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
            guard let serial = self.selectAdbDevice(adbPath: adbPath, host: phoneIp) else {
                completion(false, "No authorized ADB device found over USB or Wi-Fi.")
                return
            }
            process.arguments = ["-s", serial, "install", "-r", fileURL.path]

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
