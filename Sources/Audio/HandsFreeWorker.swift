import Foundation
import IOBluetooth
import Darwin

struct HandsFreeState: Codable, Sendable {
    var connected: Bool
    var sco: Bool
    var error: String? = nil
}

/// The legacy HFP framework has crashed in both input/output volume AT command callbacks.
/// Confine it to a worker process so an Apple framework failure cannot terminate the UI.
final class HandsFreeClient: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.droiddock.hfp.client")
    private let lock = NSLock()
    private var state = HandsFreeState(connected: false, sco: false)
    private var selectedAddress: String?
    private var process: Process?
    private var commands: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var wantsAudio = false
    private var retries = 0
    private var lastConnect = Date.distantPast
    private let executable: URL?
    private let arguments: [String]
    init(executable: URL? = Bundle.main.executableURL, arguments: [String] = []) {
        self.executable = executable; self.arguments = arguments
        signal(SIGPIPE, SIG_IGN) // A worker exiting between isRunning and write must not terminate its parent.
    }
    var snapshot: (String?, HandsFreeState) {
        lock.lock(); defer { lock.unlock() }; return (selectedAddress, state)
    }
    func connect(address: String) {
        queue.async {
            if self.snapshot.0 == address, self.process?.isRunning == true {
                if !self.snapshot.1.connected, Date().timeIntervalSince(self.lastConnect) > 10 {
                    self.lastConnect = Date(); self.write("connect")
                }
                return
            }
            self.close()
            self.lock.lock(); self.selectedAddress = address; self.lock.unlock()
            self.retries = 0
            self.launch(address: address)
        }
    }
    func command(_ command: String) {
        queue.async {
            if command == "computer" { self.wantsAudio = true }
            if command == "phone" || command == "stop" { self.wantsAudio = false }
            self.write(command)
        }
    }
    func disconnect() { queue.async { self.wantsAudio = false; self.close() } }
    private func launch(address: String) {
        guard let executable else { return }
        let child = Process(); child.executableURL = executable; child.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["DROIDLINK_HANDSFREE_HELPER"] = "1"; env["DROIDLINK_HANDSFREE_ADDRESS"] = address
        child.environment = env
        let input = Pipe(); let output = Pipe()
        child.standardInput = input; child.standardOutput = output
        child.standardError = FileHandle.standardError
        output.fileHandleForReading.readabilityHandler = { [weak self, weak child] handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil; return }
            self?.queue.async { [weak self, weak child] in
                guard let self, let child, self.process === child else { return }
                self.buffer.append(data)
                guard self.buffer.count <= 65536 else { self.close(); return }
                while let newline = self.buffer.firstIndex(of: 10) {
                    let line = Data(self.buffer[..<newline]); self.buffer.removeSubrange(...newline)
                    if let state = try? JSONDecoder().decode(HandsFreeState.self, from: line) { self.publish(state) }
                }
            }
        }
        child.terminationHandler = { [weak self] child in
            self?.queue.async { [weak self] in
                guard let self, self.process === child else { return }
                self.commands = nil; self.output?.readabilityHandler = nil; self.output = nil; self.process = nil
                self.publish(HandsFreeState(connected: false, sco: false, error: "Bluetooth call audio disconnected. Reconnect it in Settings."))
                if self.wantsAudio && self.retries < 2 {
                    self.retries += 1
                    self.queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                        guard let self, self.wantsAudio, self.process == nil, self.snapshot.0 == address else { return }
                        self.launch(address: address)
                    }
                }
            }
        }
        do {
            try child.run()
            process = child; commands = input.fileHandleForWriting; self.output = output.fileHandleForReading
            lastConnect = Date()
            if wantsAudio { write("computer") }
        } catch {
            output.fileHandleForReading.readabilityHandler = nil
            publish(HandsFreeState(connected: false, sco: false, error: "Could not start Bluetooth call audio."))
        }
    }
    private func write(_ command: String) {
        guard process?.isRunning == true else { return }
        do { try commands?.write(contentsOf: Data((command + "\n").utf8)) }
        catch { close() }
    }
    private func publish(_ newState: HandsFreeState) {
        lock.lock(); state = newState; lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("BluetoothCallAudioChanged"), object: nil) }
    }
    private func close() {
        let old = process; process = nil
        // EOF asks the worker to remove its delegate and disconnect before exiting.
        try? commands?.close(); commands = nil
        output?.readabilityHandler = nil; output = nil; buffer.removeAll()
        if let old {
            queue.asyncAfter(deadline: .now() + 2) { if old.isRunning { old.terminate() } }
        }
        lock.lock(); selectedAddress = nil; state = HandsFreeState(connected: false, sco: false); lock.unlock()
        DispatchQueue.main.async { NotificationCenter.default.post(name: .init("BluetoothCallAudioChanged"), object: nil) }
    }
}

/// One device, one retained NSObject delegate, all framework calls serialized on the main run loop.
final class HandsFreeWorker: NSObject, IOBluetoothHandsFreeDeviceDelegate, @unchecked Sendable {
    private var device: IOBluetoothHandsFreeDevice?
    private let address: String
    private var wantsAudio = false
    private var connecting = false
    private var lastConnect = Date.distantPast
    init(address: String) { self.address = address; super.init() }
    static func run() -> Never {
        signal(SIGPIPE, SIG_IGN)
        let worker = HandsFreeWorker(address: ProcessInfo.processInfo.environment["DROIDLINK_HANDSFREE_ADDRESS"] ?? "")
        withExtendedLifetime(worker) {
            worker.connect()
            DispatchQueue.global(qos: .userInitiated).async {
                while let command = readLine() { DispatchQueue.main.async { worker.handle(command) } }
                DispatchQueue.main.async { worker.handle("quit") }
            }
            RunLoop.main.run()
        }
        exit(0)
    }
    private func connect() {
        guard !connecting, Date().timeIntervalSince(lastConnect) > 5 else { return }
        lastConnect = Date()
        if device == nil {
            guard let phone = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice])?.first(where: { $0.addressString == address }),
                  let device = IOBluetoothHandsFreeDevice(device: phone, delegate: self) else {
                report(error: "The selected phone is no longer paired"); return
            }
            // HFP feature bit 4 advertises remote volume control. Both observed crashes
            // occurred in the framework's automatic volume synchronization AT commands.
            device.supportedFeatures &= ~(UInt32(1) << 4)
            self.device = device
        }
        if device?.isConnected == true { report(); return }
        connecting = true
        device?.connect()
    }
    private func handle(_ command: String) {
        switch command {
        case "connect": connect()
        case "computer": wantsAudio = true; if device?.isConnected == true { device?.transferAudioToComputer() } else { connect() }
        case "phone": wantsAudio = false; device?.transferAudioToPhone()
        case "stop": wantsAudio = false; device?.disconnectSCO()
        case "quit":
            device?.delegate = nil
            device?.disconnectSCO(); device?.disconnect()
            exit(0)
        default: break
        }
    }
    private func report(error: String? = nil) {
        let state = HandsFreeState(connected: device?.isConnected == true, sco: device?.isSCOConnected() == true, error: error)
        if let data = try? JSONEncoder().encode(state) { try? FileHandle.standardOutput.write(contentsOf: data + Data([10])) }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        DispatchQueue.main.async { [self] in
            connecting = false
            if status?.int32Value == 0 && wantsAudio { self.device?.transferAudioToComputer() }
            report()
        }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        DispatchQueue.main.async { [self] in connecting = false; report() }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        DispatchQueue.main.async { [self] in report() }
    }
    func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        DispatchQueue.main.async { [self] in report() }
    }
}
