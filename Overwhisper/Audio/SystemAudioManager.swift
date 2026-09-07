import CoreAudio
import Foundation

// MARK: - Output profile identity

/// Identifies the output "profile" the system is currently playing through.
///
/// Bluetooth headsets (AirPods in particular) keep separate volume and mute
/// state per transport profile: the stereo A2DP profile used for music and the
/// headset HFP profile used once a microphone is opened. macOS exposes both as
/// the same audio device, but a profile switch changes the device's nominal
/// sample rate, so the (device, sample rate) pair is enough to tell them apart.
struct SystemAudioOutputSignature: Hashable {
    let deviceID: AudioDeviceID
    let sampleRate: Double
}

// MARK: - Control surface (mockable)

/// The system-audio operations the mute coordinator needs. The real
/// implementation talks to AppleScript and CoreAudio; tests substitute a fake.
protocol SystemAudioControlling: AnyObject {
    func outputVolume() -> Int?
    func isOutputMuted() -> Bool?
    @discardableResult func setOutputMuted(_ muted: Bool) -> Bool
    @discardableResult func setOutputVolume(_ volume: Int) -> Bool
    func currentOutputSignature() -> SystemAudioOutputSignature?

    /// Start reporting output-device changes (default device, device list,
    /// stream format) to `handler` on the main thread.
    func startObservingOutputChanges(_ handler: @escaping () -> Void)
    func stopObservingOutputChanges()
}

// MARK: - Mute coordinator

/// Mutes system audio for the duration of a recording and restores it after,
/// tracking every output profile it touched along the way.
///
/// The mute is applied as early as possible (before the audio engine starts)
/// so the user hears silence promptly. Opening the microphone can then switch
/// a Bluetooth headset to a different output profile with its own, unmuted,
/// state. The coordinator watches for that switch and mutes the new profile
/// too; on restore it unmutes whichever profile is active and keeps watching
/// so the original profile is unmuted once the headset switches back.
@MainActor
final class SystemAudioMuteCoordinator {
    /// How long after `restore()` we keep watching for the output to switch
    /// back to a profile we muted, when every snapshot is already restored.
    static let restoreGraceInterval: TimeInterval = 5

    /// Delayed re-checks after mute/restore, in case a profile switch is not
    /// accompanied by an observable CoreAudio property change.
    static let followUpCheckDelays: [TimeInterval] = [1.5, 3]

    struct Snapshot {
        let signature: SystemAudioOutputSignature?
        let wasMuted: Bool
        let previousVolume: Int
        let usedVolumeFallback: Bool
        var restored: Bool

        func matches(_ signature: SystemAudioOutputSignature?) -> Bool {
            guard let own = self.signature, let other = signature else { return true }
            return own == other
        }
    }

    enum Phase: Equatable {
        case idle
        case muted
        case restoring
    }

    private let control: SystemAudioControlling
    private let scheduleAfter: (TimeInterval, @escaping @MainActor () -> Void) -> Void

    private(set) var phase: Phase = .idle
    private(set) var snapshots: [Snapshot] = []
    private var generation = 0

    init(
        control: SystemAudioControlling,
        scheduleAfter: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { work() }
        }
    ) {
        self.control = control
        self.scheduleAfter = scheduleAfter
    }

    // MARK: Public API

    func mute() {
        if phase != .idle {
            let pending = snapshots.filter { !$0.restored && !$0.wasMuted }.count
            if pending > 0 {
                AppLogger.system.warning("Starting a new mute with \(pending) output profile(s) still unrestored")
            }
            finish()
        }

        phase = .muted
        generation += 1
        let gen = generation

        applyMute()

        control.startObservingOutputChanges { [weak self] in
            self?.outputMayHaveChanged()
        }
        for delay in Self.followUpCheckDelays {
            scheduleAfter(delay) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.outputMayHaveChanged()
            }
        }
    }

    func restore() {
        guard phase == .muted else { return }
        phase = .restoring
        generation += 1
        let gen = generation

        restoreCurrentProfileIfNeeded()

        for delay in Self.followUpCheckDelays {
            scheduleAfter(delay) { [weak self] in
                guard let self, self.generation == gen else { return }
                self.outputMayHaveChanged()
            }
        }
        scheduleAfter(Self.restoreGraceInterval) { [weak self] in
            guard let self, self.generation == gen else { return }
            self.endRestoreGrace()
        }
    }

    /// Re-evaluate the current output against what we've muted or restored.
    /// Called from the CoreAudio observer, from delayed follow-up checks, and
    /// by the recorder right after the audio engine starts.
    func outputMayHaveChanged() {
        switch phase {
        case .idle:
            return
        case .muted:
            reassertMute()
        case .restoring:
            restoreCurrentProfileIfNeeded()
        }
    }

    // MARK: Muting

    private func applyMute() {
        // Check if volume control is supported (re-check each time in case audio device changed)
        guard let currentVolume = control.outputVolume() else {
            AppLogger.system.warning("System audio volume control not supported on current audio device")
            return
        }
        let signature = control.currentOutputSignature()

        if let muted = control.isOutputMuted(), muted {
            snapshots.append(Snapshot(signature: signature, wasMuted: true, previousVolume: currentVolume, usedVolumeFallback: false, restored: false))
            AppLogger.system.info("System already muted")
            return
        }

        // Try mute command first
        control.setOutputMuted(true)

        // Verify it actually worked - some devices silently ignore the mute command
        if let muted = control.isOutputMuted(), muted {
            snapshots.append(Snapshot(signature: signature, wasMuted: false, previousVolume: currentVolume, usedVolumeFallback: false, restored: false))
            AppLogger.system.info("Muted using mute command (\(Self.describe(signature)))")
            return
        }

        // Fallback: set volume to 0
        if control.setOutputVolume(0) {
            snapshots.append(Snapshot(signature: signature, wasMuted: false, previousVolume: currentVolume, usedVolumeFallback: true, restored: false))
            AppLogger.system.info("Muted by setting volume to 0 (was \(currentVolume), \(Self.describe(signature)))")
        }
    }

    private func reassertMute() {
        let signature = control.currentOutputSignature()

        guard let snapshot = snapshots.last(where: { $0.matches(signature) }) else {
            // Output moved to a profile we haven't touched (e.g. a Bluetooth
            // headset switched to its headset profile). Mute it too.
            AppLogger.system.info("Output changed to \(Self.describe(signature)) during recording; muting it")
            applyMute()
            return
        }

        // Same profile as before, but the mute may not have stuck across a
        // transport change that left the signature untouched.
        guard !snapshot.wasMuted, !snapshot.usedVolumeFallback else { return }
        if let muted = control.isOutputMuted(), !muted {
            control.setOutputMuted(true)
            AppLogger.system.info("Re-muted \(Self.describe(signature)) after output change")
        }
    }

    // MARK: Restoring

    private func restoreCurrentProfileIfNeeded() {
        let signature = control.currentOutputSignature()

        if let index = snapshots.lastIndex(where: { !$0.restored && $0.matches(signature) }) {
            restoreSnapshot(at: index)
        } else if let snapshot = snapshots.last(where: { $0.matches(signature) }),
                  !snapshot.wasMuted, !snapshot.usedVolumeFallback,
                  let muted = control.isOutputMuted(), muted {
            // Already restored this profile once, yet it came back muted: the
            // transport changed underneath an unchanged signature. Unmute again.
            control.setOutputMuted(false)
            AppLogger.system.info("Unmuted \(Self.describe(signature)) again after output change")
        }

        if snapshots.allSatisfy({ $0.restored }) && graceElapsed {
            finish()
        }
    }

    private func restoreSnapshot(at index: Int) {
        var snapshot = snapshots[index]
        defer {
            snapshot.restored = true
            snapshots[index] = snapshot
        }

        if snapshot.wasMuted {
            AppLogger.system.info("System was muted before recording, not restoring")
            return
        }

        if snapshot.usedVolumeFallback {
            if snapshot.previousVolume > 0, control.setOutputVolume(snapshot.previousVolume) {
                AppLogger.system.info("Restored volume to \(snapshot.previousVolume) (\(Self.describe(snapshot.signature)))")
            }
            return
        }

        if control.setOutputMuted(false) {
            AppLogger.system.info("Unmuted using mute command (\(Self.describe(snapshot.signature)))")
        }
    }

    private var graceElapsed = false

    private func endRestoreGrace() {
        graceElapsed = true
        let pending = snapshots.filter { !$0.restored }
        if pending.isEmpty {
            finish()
        } else {
            AppLogger.system.info("Still waiting for \(pending.count) output profile(s) to come back before unmuting")
        }
    }

    private func finish() {
        control.stopObservingOutputChanges()
        snapshots = []
        phase = .idle
        graceElapsed = false
        generation += 1
    }

    private static func describe(_ signature: SystemAudioOutputSignature?) -> String {
        guard let signature else { return "unknown output" }
        return "device \(signature.deviceID) @ \(Int(signature.sampleRate)) Hz"
    }
}

// MARK: - Real control: AppleScript + CoreAudio

// System audio control via AppleScript (requires non-sandboxed app)
// Note: This only works with built-in audio or audio devices that support macOS volume controls.
// External audio interfaces (like Focusrite Scarlett) may not support mute/volume control.
final class CoreAudioSystemAudioControl: SystemAudioControlling {
    private struct Listener {
        let objectID: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }

    private var systemListeners: [Listener] = []
    private var deviceListeners: [Listener] = []
    private var observedDevice: AudioDeviceID?
    private var handler: (() -> Void)?

    func outputVolume() -> Int? {
        let script = NSAppleScript(source: "output volume of (get volume settings)")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil {
            return nil
        }
        // Check for "missing value" by trying to coerce to integer
        guard result?.coerce(toDescriptorType: typeSInt32) != nil else { return nil }
        return Int(result?.int32Value ?? 0)
    }

    func isOutputMuted() -> Bool? {
        let script = NSAppleScript(source: "output muted of (get volume settings)")
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil {
            return nil
        }
        // Check for "missing value" by seeing if we can get a boolean
        guard result?.coerce(toDescriptorType: typeBoolean) != nil else { return nil }
        return result?.booleanValue
    }

    @discardableResult
    func setOutputMuted(_ muted: Bool) -> Bool {
        let script = NSAppleScript(source: "set volume output muted \(muted)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }

    @discardableResult
    func setOutputVolume(_ volume: Int) -> Bool {
        let script = NSAppleScript(source: "set volume output volume \(volume)")
        var error: NSDictionary?
        script?.executeAndReturnError(&error)
        return error == nil
    }

    func currentOutputSignature() -> SystemAudioOutputSignature? {
        guard let device = Self.defaultOutputDevice() else { return nil }
        return SystemAudioOutputSignature(deviceID: device, sampleRate: Self.nominalSampleRate(of: device) ?? 0)
    }

    // MARK: Observation

    func startObservingOutputChanges(_ handler: @escaping () -> Void) {
        stopObservingOutputChanges()
        self.handler = handler

        let systemObject = AudioObjectID(kAudioObjectSystemObject)
        let systemBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let device = Self.defaultOutputDevice()
            if device != self.observedDevice {
                self.observeDevice(device)
            }
            self.handler?()
        }
        systemListeners = [
            Listener(objectID: systemObject, address: Self.address(kAudioHardwarePropertyDefaultOutputDevice), block: systemBlock),
            Listener(objectID: systemObject, address: Self.address(kAudioHardwarePropertyDevices), block: systemBlock),
        ]
        add(systemListeners)

        observeDevice(Self.defaultOutputDevice())
    }

    func stopObservingOutputChanges() {
        remove(systemListeners)
        remove(deviceListeners)
        systemListeners = []
        deviceListeners = []
        observedDevice = nil
        handler = nil
    }

    private func observeDevice(_ device: AudioDeviceID?) {
        remove(deviceListeners)
        deviceListeners = []
        observedDevice = device
        guard let device else { return }

        let deviceBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.handler?()
        }
        deviceListeners = [
            Listener(objectID: device, address: Self.address(kAudioDevicePropertyNominalSampleRate), block: deviceBlock),
            Listener(objectID: device, address: Self.address(kAudioDevicePropertyStreamConfiguration, scope: kAudioDevicePropertyScopeOutput), block: deviceBlock),
            Listener(objectID: device, address: Self.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput), block: deviceBlock),
        ]
        add(deviceListeners)
    }

    private func add(_ listeners: [Listener]) {
        for var listener in listeners {
            AudioObjectAddPropertyListenerBlock(listener.objectID, &listener.address, DispatchQueue.main, listener.block)
        }
    }

    private func remove(_ listeners: [Listener]) {
        for var listener in listeners {
            AudioObjectRemovePropertyListenerBlock(listener.objectID, &listener.address, DispatchQueue.main, listener.block)
        }
    }

    // MARK: CoreAudio helpers

    private static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    private static func nominalSampleRate(of device: AudioDeviceID) -> Double? {
        var addr = address(kAudioDevicePropertyNominalSampleRate)
        var rate = Double(0)
        var size = UInt32(MemoryLayout<Double>.size)
        let status = AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &rate)
        guard status == noErr else { return nil }
        return rate
    }
}

// MARK: - Facade used by AppDelegate

@MainActor
enum SystemAudioManager {
    /// Longest we let the start chime hold off the mute. Chime files carry a
    /// long decay tail (Glass.aiff reports 1.65s), and while we wait, system
    /// audio the user asked to silence keeps playing into the recording. The
    /// chime's attack lands well inside this window; only ring-out is cut.
    nonisolated static let maxChimeMuteDelay: TimeInterval = 0.3

    nonisolated static func muteDelay(afterChimeOf duration: TimeInterval) -> TimeInterval {
        min(max(duration, 0), maxChimeMuteDelay)
    }

    private static let control = CoreAudioSystemAudioControl()
    private static let coordinator = SystemAudioMuteCoordinator(control: control)

    /// The first NSAppleScript execution in a process pays ~150ms of one-time
    /// component loading; run a harmless query up front so a real mute doesn't.
    static func prewarm() {
        _ = control.outputVolume()
    }

    static func muteSystemAudio() {
        coordinator.mute()
    }

    static func restoreSystemAudio() {
        coordinator.restore()
    }

    /// Call once the audio engine is running: opening the microphone may have
    /// switched a Bluetooth headset to a different output profile.
    static func outputDeviceMayHaveChanged() {
        coordinator.outputMayHaveChanged()
    }
}
