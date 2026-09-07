import XCTest
@testable import Overwhisper

/// Simulates an output device whose mute/volume state is stored per profile,
/// the way Bluetooth headsets keep separate A2DP (stereo) and HFP (headset)
/// state. `signature` selects which profile the "system" is currently on.
private final class FakeSystemAudioControl: SystemAudioControlling {
    struct ProfileState {
        var muted: Bool
        var volume: Int
        var supportsMute = true
        var supportsVolume = true
    }

    var profiles: [SystemAudioOutputSignature: ProfileState] = [:]
    var signature: SystemAudioOutputSignature?
    var observing = false
    var handler: (() -> Void)?

    static let stereo = SystemAudioOutputSignature(deviceID: 86, sampleRate: 48_000)
    static let headset = SystemAudioOutputSignature(deviceID: 86, sampleRate: 24_000)

    init(current: SystemAudioOutputSignature?, profiles: [SystemAudioOutputSignature: ProfileState]) {
        self.signature = current
        self.profiles = profiles
    }

    private var current: ProfileState? {
        get { signature.flatMap { profiles[$0] } }
        set { if let signature, let newValue { profiles[signature] = newValue } }
    }

    func outputVolume() -> Int? {
        guard let current, current.supportsVolume else { return nil }
        return current.volume
    }

    func isOutputMuted() -> Bool? {
        guard let current, current.supportsMute else { return nil }
        return current.muted
    }

    func setOutputMuted(_ muted: Bool) -> Bool {
        guard var state = current, state.supportsMute else { return true }
        state.muted = muted
        current = state
        return true
    }

    func setOutputVolume(_ volume: Int) -> Bool {
        guard var state = current, state.supportsVolume else { return false }
        state.volume = volume
        current = state
        return true
    }

    func currentOutputSignature() -> SystemAudioOutputSignature? { signature }

    func startObservingOutputChanges(_ handler: @escaping () -> Void) {
        observing = true
        self.handler = handler
    }

    func stopObservingOutputChanges() {
        observing = false
        handler = nil
    }

    /// The system switches output profile and CoreAudio notifies us.
    func switchTo(_ signature: SystemAudioOutputSignature) {
        self.signature = signature
        handler?()
    }

    subscript(_ signature: SystemAudioOutputSignature) -> ProfileState { profiles[signature]! }
}

@MainActor
final class SystemAudioMuteCoordinatorTests: XCTestCase {
    private typealias Fake = FakeSystemAudioControl

    private var scheduled: [(delay: TimeInterval, work: @MainActor () -> Void)] = []

    private func makeCoordinator(_ control: Fake) -> SystemAudioMuteCoordinator {
        SystemAudioMuteCoordinator(control: control) { [unowned self] delay, work in
            self.scheduled.append((delay, work))
        }
    }

    /// Run every timer that has been scheduled so far, in delay order.
    private func fireTimers() {
        let pending = scheduled.sorted { $0.delay < $1.delay }
        scheduled = []
        pending.forEach { $0.work() }
    }

    override func setUp() {
        super.setUp()
        scheduled = []
    }

    // MARK: AirPods-style profile switch

    func testMutesHeadsetProfileReachedAfterMicOpensAndUnmutesBothAfterwards() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
            Fake.headset: .init(muted: false, volume: 10),
        ])
        let coordinator = makeCoordinator(control)

        // Hotkey: mute lands on the stereo profile before the engine starts.
        coordinator.mute()
        XCTAssertTrue(control[Fake.stereo].muted)
        XCTAssertTrue(control.observing)

        // Engine starts, headset flips to HFP with its own unmuted state.
        control.switchTo(Fake.headset)
        XCTAssertTrue(control[Fake.headset].muted, "headset profile must be muted during recording")
        XCTAssertEqual(coordinator.snapshots.count, 2)

        // Stop: restore runs while still on the headset profile.
        coordinator.restore()
        XCTAssertFalse(control[Fake.headset].muted)
        XCTAssertTrue(control[Fake.stereo].muted, "stereo profile can't be reached yet")
        XCTAssertTrue(control.observing, "must keep watching for the switch back")

        // Engine stops, headset returns to A2DP.
        control.switchTo(Fake.stereo)
        XCTAssertFalse(control[Fake.stereo].muted, "stereo profile must be unmuted once it comes back")
        XCTAssertFalse(control[Fake.headset].muted)

        fireTimers()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(control.observing)
    }

    func testRecheckAfterEngineStartMutesHeadsetProfileWithoutObserverEvent() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
            Fake.headset: .init(muted: false, volume: 10),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        control.signature = Fake.headset  // switched silently
        coordinator.outputMayHaveChanged()  // AppDelegate's post-engine-start check
        XCTAssertTrue(control[Fake.headset].muted)
    }

    func testDelayedFollowUpUnmutesStereoProfileWhenSwitchBackIsSilent() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
            Fake.headset: .init(muted: false, volume: 10),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        control.switchTo(Fake.headset)
        coordinator.restore()
        control.signature = Fake.stereo  // came back without a CoreAudio event
        fireTimers()
        XCTAssertFalse(control[Fake.stereo].muted)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testKeepsWatchingPastGraceWhileAMutedProfileIsStillAway() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
            Fake.headset: .init(muted: false, volume: 10),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        control.switchTo(Fake.headset)
        coordinator.restore()
        fireTimers()  // grace elapses; another app still holds the mic
        XCTAssertEqual(coordinator.phase, .restoring)
        XCTAssertTrue(control.observing)

        control.switchTo(Fake.stereo)
        XCTAssertFalse(control[Fake.stereo].muted)
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(control.observing)
    }

    // MARK: Respecting the user's own mute

    func testDoesNotUnmuteAProfileTheUserHadMuted() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: true, volume: 60),
            Fake.headset: .init(muted: false, volume: 10),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        control.switchTo(Fake.headset)
        XCTAssertTrue(control[Fake.headset].muted)

        coordinator.restore()
        control.switchTo(Fake.stereo)
        fireTimers()
        XCTAssertFalse(control[Fake.headset].muted)
        XCTAssertTrue(control[Fake.stereo].muted, "the user muted this themselves")
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: Same signature, per-transport state

    func testReassertsMuteWhenTransportChangesUnderAnUnchangedSignature() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        // Transport flips but reports the same device/sample rate, and the new
        // transport is unmuted.
        control.profiles[Fake.stereo]!.muted = false
        control.handler?()
        XCTAssertTrue(control[Fake.stereo].muted)
        XCTAssertEqual(coordinator.snapshots.count, 1)

        coordinator.restore()
        XCTAssertFalse(control[Fake.stereo].muted)
        // Switch back to the original transport, which we muted first.
        control.profiles[Fake.stereo]!.muted = true
        control.handler?()
        XCTAssertFalse(control[Fake.stereo].muted)
    }

    // MARK: Volume fallback

    func testVolumeFallbackIsTrackedPerProfile() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
            Fake.headset: .init(muted: false, volume: 12, supportsMute: false),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        control.switchTo(Fake.headset)
        XCTAssertEqual(control[Fake.headset].volume, 0)

        coordinator.restore()
        XCTAssertEqual(control[Fake.headset].volume, 12, "restores the headset profile's own volume")
        control.switchTo(Fake.stereo)
        XCTAssertFalse(control[Fake.stereo].muted)
        XCTAssertEqual(control[Fake.stereo].volume, 60)
    }

    // MARK: Ordinary devices

    func testSingleProfileDeviceMutesAndRestoresThenStopsObserving() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        XCTAssertTrue(control[Fake.stereo].muted)
        coordinator.restore()
        XCTAssertFalse(control[Fake.stereo].muted)
        XCTAssertEqual(coordinator.phase, .restoring)
        fireTimers()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(control.observing)
    }

    func testUnsupportedDeviceIsLeftAlone() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60, supportsMute: false, supportsVolume: false),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        XCTAssertTrue(coordinator.snapshots.isEmpty)
        coordinator.restore()
        fireTimers()
        XCTAssertFalse(control[Fake.stereo].muted)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testRestoreWithoutMuteIsANoOp() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
        ])
        let coordinator = makeCoordinator(control)
        coordinator.restore()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertTrue(scheduled.isEmpty)
    }

    func testStaleTimersFromAPreviousSessionAreIgnored() {
        let control = Fake(current: Fake.stereo, profiles: [
            Fake.stereo: .init(muted: false, volume: 60),
        ])
        let coordinator = makeCoordinator(control)

        coordinator.mute()
        coordinator.restore()
        let stale = scheduled
        scheduled = []

        // A new recording starts before the previous restore's grace elapses.
        coordinator.mute()
        XCTAssertEqual(coordinator.phase, .muted)
        XCTAssertTrue(control[Fake.stereo].muted)

        stale.forEach { $0.work() }
        XCTAssertEqual(coordinator.phase, .muted, "old timers must not end the new session")
        XCTAssertTrue(control[Fake.stereo].muted)
        XCTAssertTrue(control.observing)

        coordinator.restore()
        fireTimers()
        XCTAssertEqual(coordinator.phase, .idle)
        XCTAssertFalse(control[Fake.stereo].muted)
    }
}
