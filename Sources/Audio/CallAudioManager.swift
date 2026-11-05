import Foundation
@preconcurrency import AVFoundation
import CoreAudio
import IOBluetooth

public struct AudioDeviceItem: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    public let isInput: Bool
    public let isOutput: Bool
    public let isBluetooth: Bool
}

public final class CallAudioManager: NSObject, @unchecked Sendable {
    public static let shared = CallAudioManager()

    private var handsFreeDevice: IOBluetoothHandsFreeDevice?
    private var targetDeviceName: String?

    private let dtmfFrequencies: [Character: (Double, Double)] = [
        "1": (697, 1209), "2": (697, 1336), "3": (697, 1477),
        "4": (770, 1209), "5": (770, 1336), "6": (770, 1477),
        "7": (852, 1209), "8": (852, 1336), "9": (852, 1477),
        "*": (941, 1209), "0": (941, 1336), "#": (941, 1477)
    ]

    public override init() {
        super.init()
    }

    public func pairedPhones() -> [IOBluetoothDevice] {
        (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []).filter {
            $0.isHandsFreeAudioGateway || $0.deviceClassMajor == 0x02
        }
    }

    public func connectPhone(address: String) {
        guard let device = pairedPhones().first(where: { $0.addressString == address }) else { return }
        UserDefaults.standard.set(address, forKey: "callBluetoothPhoneAddress")
        targetDeviceName = device.name
        handsFreeDevice?.disconnect()
        handsFreeDevice = IOBluetoothHandsFreeDevice(device: device, delegate: self)
        handsFreeDevice?.connect()
    }

    // MARK: - Bluetooth Audio Gateway & Hands-Free
    public func autoConnectBluetooth(deviceName: String?) {
        if let address = UserDefaults.standard.string(forKey: "callBluetoothPhoneAddress"),
           let device = pairedPhones().first(where: { $0.addressString == address }) {
            targetDeviceName = device.name
            if handsFreeDevice?.device != device { connectPhone(address: address) }
            else if handsFreeDevice?.isConnected != true { handsFreeDevice?.connect() }
            return
        }
        guard let name = deviceName?.lowercased(), !name.isEmpty else { return }
        self.targetDeviceName = name

        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        // Do not select a keyboard/headset merely because its name is empty or similar.
        if let match = paired.first(where: {
            Self.matchesPhoneName($0.name ?? "", target: name) && $0.isHandsFreeAudioGateway
        }) {
            if self.handsFreeDevice?.device != match {
                self.handsFreeDevice?.disconnect()
                self.handsFreeDevice = IOBluetoothHandsFreeDevice(device: match, delegate: self)
            }
            if self.handsFreeDevice?.isConnected != true { self.handsFreeDevice?.connect() }
        }
    }

    public static func matchesPhoneName(_ name: String, target: String) -> Bool {
        let name = name.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let target = target.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !target.isEmpty else { return false }
        return name == target || name.hasSuffix(" " + target) || target.hasSuffix(" " + name)
    }

    private var wantsCallAudio = false

    public func startCallAudioRouting() {
        wantsCallAudio = true
        guard handsFreeDevice?.isConnected == true else {
            autoConnectBluetooth(deviceName: targetDeviceName)
            return
        }
        handsFreeDevice?.transferAudioToComputer()
    }

    public func transferAudioToPhone() {
        wantsCallAudio = false
        handsFreeDevice?.transferAudioToPhone()
    }

    public func stopCallAudioRouting() {
        wantsCallAudio = false
        handsFreeDevice?.disconnectSCO()
    }

    public func disconnectPhone() {
        stopCallAudioRouting()
        handsFreeDevice?.disconnect()
        handsFreeDevice = nil
        targetDeviceName = nil
        UserDefaults.standard.removeObject(forKey: "callBluetoothPhoneAddress")
    }

    public func isBluetoothHandsetAvailable(deviceName: String? = nil) -> Bool {
        guard let handsFreeDevice, handsFreeDevice.isConnected else { return false }
        if let selected = UserDefaults.standard.string(forKey: "callBluetoothPhoneAddress"), handsFreeDevice.device?.addressString == selected { return true }
        guard let target = deviceName ?? targetDeviceName else { return false }
        return Self.matchesPhoneName(handsFreeDevice.device?.name ?? "", target: target)
    }

    public var isCallAudioConnected: Bool { handsFreeDevice?.isSCOConnected() == true }

    // MARK: - CoreAudio Device Management
    public func getAvailableAudioDevices() -> [AudioDeviceItem] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize
        )

        guard status == noErr else { return [] }

        let deviceCount = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)

        let getStatus = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &deviceIDs
        )

        guard getStatus == noErr else { return [] }

        var items: [AudioDeviceItem] = []
        for id in deviceIDs {
            let name = getDeviceName(id: id)
            let isInput = hasStream(id: id, isInput: true)
            let isOutput = hasStream(id: id, isInput: false)
            let isBluetooth = isBluetoothDevice(id: id)

            items.append(AudioDeviceItem(
                id: id,
                name: name,
                isInput: isInput,
                isOutput: isOutput,
                isBluetooth: isBluetooth
            ))
        }

        return items
    }

    private func isBluetoothDevice(id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &transport) == noErr else { return false }
        return transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE
    }

    private func getDeviceName(id: AudioDeviceID) -> String {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var cfName: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(id, &propertyAddress, 0, nil, &dataSize, &cfName)
        if status == noErr, let name = cfName?.takeRetainedValue() {
            return name as String
        }
        return "Audio Device \(id)"
    }

    private func hasStream(id: AudioDeviceID, isInput: Bool) -> Bool {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams,
            mScope: isInput ? kAudioDevicePropertyScopeInput : kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(id, &propertyAddress, 0, nil, &dataSize)
        return status == noErr && dataSize > 0
    }

    public func getDefaultOutputDevice() -> AudioDeviceID? {
        var devId: AudioDeviceID = 0
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            &dataSize,
            &devId
        )
        return status == noErr && devId != 0 ? devId : nil
    }

    public func getDefaultInputDevice() -> AudioDeviceID? {
        var device: AudioDeviceID = 0
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return status == noErr && device != 0 ? device : nil
    }

    public func setDefaultOutputDevice(id: AudioDeviceID) {
        var devId = id
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devId
        )
    }

    public func setDefaultInputDevice(id: AudioDeviceID) {
        var devId = id
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &propertyAddress,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devId
        )
    }

    // MARK: - DTMF Audio Tone Playback
    public func playDtmfTone(digit: Character, duration: TimeInterval = 0.15) {
        guard let (f1, f2) = dtmfFrequencies[digit] else { return }

        let sampleRate = 44100.0
        var phase1 = 0.0
        var phase2 = 0.0
        let phaseIncrement1 = 2.0 * .pi * f1 / sampleRate
        let phaseIncrement2 = 2.0 * .pi * f2 / sampleRate

        let toneEngine = AVAudioEngine()
        let sourceNode = AVAudioSourceNode { _, _, frameCount, audioBufferList -> OSStatus in
            let ablPointer = UnsafeMutableAudioBufferListPointer(audioBufferList)
            for frame in 0..<Int(frameCount) {
                let sampleVal = Float(sin(phase1) + sin(phase2)) * 0.2
                phase1 += phaseIncrement1
                phase2 += phaseIncrement2
                if phase1 > 2.0 * .pi { phase1 -= 2.0 * .pi }
                if phase2 > 2.0 * .pi { phase2 -= 2.0 * .pi }

                for buffer in ablPointer {
                    let buf: UnsafeMutableBufferPointer<Float> = UnsafeMutableBufferPointer(buffer)
                    buf[frame] = sampleVal
                }
            }
            return noErr
        }

        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1)!
        toneEngine.attach(sourceNode)
        toneEngine.connect(sourceNode, to: toneEngine.mainMixerNode, format: format)

        try? toneEngine.start()
        DispatchQueue.global().asyncAfter(deadline: .now() + duration) {
            toneEngine.stop()
        }
    }
}

extension CallAudioManager: IOBluetoothHandsFreeDeviceDelegate {
    public func handsFree(_ device: IOBluetoothHandsFree!, connected status: NSNumber!) {
        if status?.int32Value == 0 && wantsCallAudio { startCallAudioRouting() }
        NotificationCenter.default.post(name: .init("BluetoothCallAudioChanged"), object: nil)
    }

    public func handsFree(_ device: IOBluetoothHandsFree!, disconnected status: NSNumber!) {
        NotificationCenter.default.post(name: .init("BluetoothCallAudioChanged"), object: nil)
    }

    public func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionOpened status: NSNumber!) {
        NotificationCenter.default.post(name: .init("BluetoothCallAudioChanged"), object: nil)
    }

    public func handsFree(_ device: IOBluetoothHandsFree!, scoConnectionClosed status: NSNumber!) {
        NotificationCenter.default.post(name: .init("BluetoothCallAudioChanged"), object: nil)
    }
}
