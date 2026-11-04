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

    // MARK: - Bluetooth Audio Gateway & Hands-Free
    public func autoConnectBluetooth(deviceName: String?) {
        guard let name = deviceName?.lowercased(), !name.isEmpty else { return }
        self.targetDeviceName = name

        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else { return }
        if let match = paired.first(where: {
            let dName = ($0.name ?? "").lowercased()
            return dName.contains(name) || name.contains(dName)
        }) {
            if !match.isConnected() {
                match.openConnection()
            }
            if self.handsFreeDevice == nil || self.handsFreeDevice?.device != match {
                self.handsFreeDevice = IOBluetoothHandsFreeDevice(device: match, delegate: self)
            }
            self.handsFreeDevice?.connect()
            print("[CallAudioManager] Auto-connected IOBluetoothHandsFreeDevice to \(match.name ?? "phone")")
        }
    }

    public func startCallAudioRouting() {
        print("[CallAudioManager] Starting Bluetooth call audio routing via SCO")
        handsFreeDevice?.connectSCO()
        handsFreeDevice?.transferAudioToComputer()
    }

    public func stopCallAudioRouting() {
        print("[CallAudioManager] Stopping Bluetooth call audio routing")
        handsFreeDevice?.disconnectSCO()
    }

    public func dialViaHandsFree(number: String) {
        handsFreeDevice?.dialNumber(number)
    }

    public func answerViaHandsFree() {
        handsFreeDevice?.acceptCall()
    }

    public func hangupViaHandsFree() {
        handsFreeDevice?.endCall()
    }

    public func isBluetoothHandsetAvailable(deviceName: String? = nil) -> Bool {
        if handsFreeDevice?.isConnected == true {
            return true
        }

        guard let paired = IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] else {
            let devices = getAvailableAudioDevices()
            return devices.contains(where: { $0.isBluetooth })
        }

        let target = (deviceName ?? targetDeviceName ?? "").lowercased()
        if !target.isEmpty {
            if paired.contains(where: {
                let dName = ($0.name ?? "").lowercased()
                return (dName.contains(target) || target.contains(dName)) && $0.isConnected()
            }) {
                return true
            }
        }

        if paired.contains(where: {
            $0.isConnected() && ($0.deviceClassMajor == 0x02 || ($0.name ?? "").lowercased().contains("pixel") || ($0.name ?? "").lowercased().contains("phone"))
        }) {
            return true
        }

        if paired.contains(where: { $0.isConnected() }) {
            return true
        }

        let devices = getAvailableAudioDevices()
        return devices.contains(where: { $0.isBluetooth })
    }

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
            let isBluetooth = name.lowercased().contains("bluetooth") || name.lowercased().contains("hands-free") || name.lowercased().contains("airpods")

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
    public func handsFree(_ handsFree: IOBluetoothHandsFree!, deviceConnected device: IOBluetoothDevice!) {
        print("[CallAudioManager] HandsFree connected to: \(device?.name ?? "unknown")")
    }

    public func handsFree(_ handsFree: IOBluetoothHandsFree!, deviceDisconnected device: IOBluetoothDevice!) {
        print("[CallAudioManager] HandsFree disconnected from: \(device?.name ?? "unknown")")
    }
}
