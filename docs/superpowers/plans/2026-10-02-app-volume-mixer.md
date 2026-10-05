# App Volume Mixer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Menu bar app that sets volume per application on macOS.

**Architecture:** `MixerCore` library holds all logic. Pure units (`VolumeStore`, `Gain`, `Renderer`, `AppGrouping`, `MixerEngine`) are unit tested; Core Audio units (`AudioProcessMonitor`, `TapVolumeController`, `AudioCapturePermission`) sit behind protocols and closures so the engine is tested with fakes. `VolumeMixer` executable is a thin SwiftUI `MenuBarExtra`.

**Tech Stack:** Swift 6.3 toolchain in Swift 5 language mode, SwiftPM, Core Audio process taps, SwiftUI, Observation, Synchronization (`Atomic`), ServiceManagement, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-10-02-app-volume-mixer-design.md`

## Global Constraints

- macOS 15.0 minimum (process taps need 14.2; `Synchronization.Atomic` needs 15).
- No third-party dependencies.
- Volume range 0–100%, no boost. Slider position `p` maps to gain `p²`.
- At 100% and unmuted, no tap exists for that app.
- IOProc: no allocation, no locks, no Objective-C messaging.
- No Dock icon (`LSUIElement`). Bundle ID `local.volumemixer.VolumeMixer`.
- Dark appearance only, regardless of system setting.
- Tool output: pipe builds and tests through `tail`/`grep`, under 100 lines.
- No git repository here; no commit steps. Each task ends with its tests green.

## Review Focus

Each line has a test in the named task.

1. Saved data is garbage or out of range (hand-edited defaults, old format): store falls back to full volume, clamps to 0…1. Task 1.
2. Output device layout differs from the tap (mono, non-interleaved, more frames than input): no overrun, leftover output is silence. Task 2.
3. Audio comes from a helper with no regular parent, or a process with no bundle ID: grouped by fallback or skipped, never a crash. Task 3.
4. Tap creation fails for one app: that row is flagged, other apps keep working, moving the slider retries. Task 4.
5. Permission denied or not yet decided: no taps created, one request only, taps appear once granted. Task 4.

## File Structure

```
Package.swift
.gitignore
Resources/Info.plist
scripts/build.sh
scripts/install.sh
Sources/MixerCore/
  VolumeStore.swift            AppVolume + persistence
  Gain.swift                   slider curve, ramp step
  Renderer.swift               real-time copy with ramped gain
  AppGrouping.swift            process to owning app
  MixerEngine.swift            protocols + reconcile logic + rows
  CoreAudioSupport.swift       property read helpers
  AudioProcessMonitor.swift    process list, AppDescriber
  TapVolumeController.swift    tap + aggregate device + IOProc
  AudioCapturePermission.swift TCC preflight / request
  LoginItem.swift              SMAppService wrapper
Sources/VolumeMixer/
  VolumeMixerApp.swift         app entry + wiring
  MixerView.swift              popover
  AppRowView.swift             one app row
Tests/MixerCoreTests/
  VolumeStoreTests.swift  GainTests.swift  RendererTests.swift
  AppGroupingTests.swift  MixerEngineTests.swift
```

---

### Task 1: Package, VolumeStore, Gain

**Files:**
- Create: `Package.swift`, `.gitignore`, `Sources/MixerCore/VolumeStore.swift`, `Sources/MixerCore/Gain.swift`
- Test: `Tests/MixerCoreTests/VolumeStoreTests.swift`, `Tests/MixerCoreTests/GainTests.swift`

**Interfaces:**
- Produces: `AppVolume(volume: Float = 1, muted: Bool = false)`, `.isDefault`; `VolumeStore(defaults:key:)`, `.all`, `.volume(for:)`, `.set(_:for:)`; `Gain.curve(_:)`, `Gain.gain(for:)`, `Gain.rampStep(sampleRate:seconds:)`.

- [ ] **Step 1: Package manifest and ignore file**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "VolumeMixer",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "MixerCore"),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore"]),
    ],
    swiftLanguageModes: [.v5]
)
```

`.gitignore`:

```
.build/
build/
.DS_Store
```

- [ ] **Step 2: Write failing tests**

`Tests/MixerCoreTests/VolumeStoreTests.swift`:

```swift
import Foundation
import Testing
@testable import MixerCore

struct VolumeStoreTests {
    let defaults = UserDefaults(suiteName: "VolumeStoreTests-\(UUID().uuidString)")!

    @Test func unknownAppIsFullVolume() {
        let store = VolumeStore(defaults: defaults)
        #expect(store.volume(for: "com.example.a") == AppVolume(volume: 1, muted: false))
        #expect(store.volume(for: "com.example.a").isDefault)
    }

    @Test func roundTripsAcrossInstances() {
        VolumeStore(defaults: defaults).set(AppVolume(volume: 0.4, muted: true), for: "com.example.a")
        #expect(VolumeStore(defaults: defaults).volume(for: "com.example.a") == AppVolume(volume: 0.4, muted: true))
    }

    @Test func muteAtFullVolumeIsStored() {
        let store = VolumeStore(defaults: defaults)
        store.set(AppVolume(volume: 1, muted: true), for: "com.example.a")
        #expect(store.all["com.example.a"] == AppVolume(volume: 1, muted: true))
    }

    @Test func defaultValueIsRemoved() {
        let store = VolumeStore(defaults: defaults)
        store.set(AppVolume(volume: 0.5), for: "com.example.a")
        store.set(AppVolume(volume: 1), for: "com.example.a")
        #expect(store.all.isEmpty)
    }

    @Test func clampsOutOfRangeAndNaN() {
        #expect(AppVolume(volume: 1.7).volume == 1)
        #expect(AppVolume(volume: -0.3).volume == 0)
        #expect(AppVolume(volume: .nan).volume == 1)
    }

    @Test func clampsOutOfRangeSavedData() {
        defaults.set(Data(#"{"com.example.a":{"volume":5,"muted":false}}"#.utf8), forKey: "appVolumes")
        #expect(VolumeStore(defaults: defaults).volume(for: "com.example.a").volume == 1)
    }

    @Test func garbageSavedDataFallsBackToEmpty() {
        defaults.set(Data([1, 2, 3]), forKey: "appVolumes")
        #expect(VolumeStore(defaults: defaults).all.isEmpty)
        defaults.set("junk", forKey: "appVolumes")
        #expect(VolumeStore(defaults: defaults).all.isEmpty)
    }
}
```

`Tests/MixerCoreTests/GainTests.swift`:

```swift
import Testing
@testable import MixerCore

struct GainTests {
    @Test func curveIsSquared() {
        #expect(Gain.curve(0) == 0)
        #expect(Gain.curve(0.5) == 0.25)
        #expect(Gain.curve(1) == 1)
    }

    @Test func curveClamps() {
        #expect(Gain.curve(2) == 1)
        #expect(Gain.curve(-1) == 0)
        #expect(Gain.curve(.nan) == 1)
    }

    @Test func muteForcesZero() {
        #expect(Gain.gain(for: AppVolume(volume: 0.5, muted: true)) == 0)
        #expect(Gain.gain(for: AppVolume(volume: 0.5, muted: false)) == 0.25)
    }

    @Test func rampStepCoversFullRangeInTenMilliseconds() {
        #expect(abs(Gain.rampStep(sampleRate: 48000) - 1.0 / 480.0) < 1e-7)
        #expect(Gain.rampStep(sampleRate: 0) == 1)
    }
}
```

- [ ] **Step 3: Run, expect failure**

Run: `swift test 2>&1 | grep -E "error|Compiling|passed|failed" | head -20`
Expected: compile errors, `cannot find 'VolumeStore' in scope`.

- [ ] **Step 4: Implement**

`Sources/MixerCore/VolumeStore.swift`:

```swift
import Foundation

public struct AppVolume: Codable, Equatable, Sendable {
    /// Slider position, 0...1.
    public var volume: Float
    public var muted: Bool

    public init(volume: Float = 1, muted: Bool = false) {
        self.volume = volume.isNaN ? 1 : min(max(volume, 0), 1)
        self.muted = muted
    }

    public var isDefault: Bool { volume >= 1 && !muted }
}

public final class VolumeStore {
    private let defaults: UserDefaults
    private let key: String
    private var cache: [String: AppVolume]

    public init(defaults: UserDefaults = .standard, key: String = "appVolumes") {
        self.defaults = defaults
        self.key = key
        if let data = defaults.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: AppVolume].self, from: data) {
            // Synthesized decoding skips init, so clamp here.
            cache = decoded.mapValues { AppVolume(volume: $0.volume, muted: $0.muted) }
        } else {
            cache = [:]
        }
    }

    public var all: [String: AppVolume] { cache }

    public func volume(for bundleID: String) -> AppVolume {
        cache[bundleID] ?? AppVolume()
    }

    public func set(_ volume: AppVolume, for bundleID: String) {
        cache[bundleID] = volume.isDefault ? nil : volume
        defaults.set(try? JSONEncoder().encode(cache), forKey: key)
    }
}
```

`Sources/MixerCore/Gain.swift`:

```swift
public enum Gain {
    /// Slider position to linear gain. Squared so the slider feels even to the ear.
    public static func curve(_ position: Float) -> Float {
        let clamped = position.isNaN ? 1 : min(max(position, 0), 1)
        return clamped * clamped
    }

    public static func gain(for volume: AppVolume) -> Float {
        volume.muted ? 0 : curve(volume.volume)
    }

    /// Per-frame gain change so a full 0...1 sweep takes `seconds`.
    public static func rampStep(sampleRate: Double, seconds: Double = 0.010) -> Float {
        sampleRate > 0 ? Float(1 / (sampleRate * seconds)) : 1
    }
}
```

- [ ] **Step 5: Run, expect pass**

Run: `swift test 2>&1 | grep -E "error|passed|failed" | tail -15`
Expected: 11 tests passed.

---

### Task 2: Renderer

**Files:**
- Create: `Sources/MixerCore/Renderer.swift`
- Test: `Tests/MixerCoreTests/RendererTests.swift`

**Interfaces:**
- Produces: `Renderer.process(input: UnsafePointer<AudioBufferList>, output: UnsafeMutablePointer<AudioBufferList>, current: inout Float, target: Float, step: Float)`. Samples are Float32. `current` is the gain after the last frame.

- [ ] **Step 1: Write failing tests**

`Tests/MixerCoreTests/RendererTests.swift`:

```swift
import CoreAudio
import Testing
@testable import MixerCore

/// Owns an AudioBufferList. `layout` is channels per buffer: [2] interleaved stereo, [1, 1] planar stereo.
final class TestBuffers {
    let list: UnsafeMutableAudioBufferListPointer
    private let frames: Int

    init(layout: [Int], frames: Int, fill: (_ channel: Int, _ frame: Int) -> Float = { _, _ in 0 }) {
        self.frames = frames
        list = AudioBufferList.allocate(maximumBuffers: layout.count)
        var firstChannel = 0
        for (index, channels) in layout.enumerated() {
            let data = UnsafeMutablePointer<Float>.allocate(capacity: max(channels * frames, 1))
            for frame in 0..<frames {
                for channel in 0..<channels {
                    data[frame * channels + channel] = fill(firstChannel + channel, frame)
                }
            }
            list[index] = AudioBuffer(
                mNumberChannels: UInt32(channels),
                mDataByteSize: UInt32(channels * frames * MemoryLayout<Float>.size),
                mData: data)
            firstChannel += channels
        }
    }

    deinit {
        for buffer in list { buffer.mData?.deallocate() }
        list.unsafeMutablePointer.deallocate()
    }

    func channel(_ index: Int) -> [Float] {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            if remaining < channels {
                let data = buffer.mData!.assumingMemoryBound(to: Float.self)
                return (0..<frames).map { data[$0 * channels + remaining] }
            }
            remaining -= channels
        }
        return []
    }
}

struct RendererTests {
    private func run(_ input: TestBuffers, _ output: TestBuffers, current: Float, target: Float, step: Float = 1) -> Float {
        var gain = current
        Renderer.process(input: input.list.unsafePointer, output: output.list.unsafeMutablePointer,
                         current: &gain, target: target, step: step)
        return gain
    }

    @Test func unityGainCopies() {
        let input = TestBuffers(layout: [2], frames: 4) { channel, frame in channel == 0 ? Float(frame + 1) : -Float(frame + 1) }
        let output = TestBuffers(layout: [2], frames: 4)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 2, 3, 4])
        #expect(output.channel(1) == [-1, -2, -3, -4])
    }

    @Test func scalesByGain() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 0.25, target: 0.25)
        #expect(output.channel(0) == [0.25, 0.25])
        #expect(output.channel(1) == [0.25, 0.25])
    }

    @Test func rampsTowardTarget() {
        let input = TestBuffers(layout: [2], frames: 5) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 5)
        let end = run(input, output, current: 1, target: 0, step: 0.25)
        #expect(output.channel(0) == [0.75, 0.5, 0.25, 0, 0])
        #expect(end == 0)
    }

    @Test func rampsUpWithoutOvershoot() {
        let input = TestBuffers(layout: [2], frames: 3) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 3)
        let end = run(input, output, current: 0, target: 0.5, step: 0.375)
        #expect(output.channel(0) == [0.375, 0.5, 0.5])
        #expect(end == 0.5)
    }

    @Test func monoOutputAveragesChannels() {
        let input = TestBuffers(layout: [2], frames: 2) { channel, _ in channel == 0 ? 1 : 0 }
        let output = TestBuffers(layout: [1], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [0.5, 0.5])
    }

    @Test func monoInputFeedsBothOutputs() {
        let input = TestBuffers(layout: [1], frames: 2) { _, _ in 0.5 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [0.5, 0.5])
        #expect(output.channel(1) == [0.5, 0.5])
    }

    @Test func planarInputToInterleavedOutput() {
        let input = TestBuffers(layout: [1, 1], frames: 2) { channel, _ in channel == 0 ? 1 : 2 }
        let output = TestBuffers(layout: [2], frames: 2)
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1])
        #expect(output.channel(1) == [2, 2])
    }

    @Test func outputLongerThanInputIsSilentAfterInputEnds() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [2], frames: 4) { _, _ in 9 }
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1, 0, 0])
        #expect(output.channel(1) == [1, 1, 0, 0])
    }

    @Test func extraOutputChannelsAreSilent() {
        let input = TestBuffers(layout: [2], frames: 2) { _, _ in 1 }
        let output = TestBuffers(layout: [4], frames: 2) { _, _ in 9 }
        _ = run(input, output, current: 1, target: 1)
        #expect(output.channel(0) == [1, 1])
        #expect(output.channel(2) == [0, 0])
        #expect(output.channel(3) == [0, 0])
    }

    @Test func emptyInputLeavesSilence() {
        let input = TestBuffers(layout: [2], frames: 0)
        let output = TestBuffers(layout: [2], frames: 2) { _, _ in 9 }
        let end = run(input, output, current: 0.3, target: 1, step: 0.1)
        #expect(output.channel(0) == [0, 0])
        #expect(end == 0.3)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter RendererTests 2>&1 | grep -E "error|passed|failed" | head -10`
Expected: `cannot find 'Renderer' in scope`.

- [ ] **Step 3: Implement**

`Sources/MixerCore/Renderer.swift`:

```swift
import CoreAudio

public enum Renderer {
    private typealias Channel = (samples: UnsafeMutablePointer<Float>, stride: Int, frames: Int)

    /// Copies the first two input channels to the first two output channels, scaled by a gain
    /// that moves toward `target` by at most `step` per frame. Real-time safe.
    public static func process(
        input: UnsafePointer<AudioBufferList>,
        output: UnsafeMutablePointer<AudioBufferList>,
        current: inout Float,
        target: Float,
        step: Float
    ) {
        let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
        let outputs = UnsafeMutableAudioBufferListPointer(output)
        for buffer in outputs {
            if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
        }

        guard let inLeft = channel(inputs, 0), let outLeft = channel(outputs, 0) else { return }
        let inRight = channel(inputs, 1) ?? inLeft
        let outRight = channel(outputs, 1)
        let frames = min(inLeft.frames, inRight.frames, outLeft.frames, outRight?.frames ?? .max)

        var gain = current
        for frame in 0..<frames {
            if gain < target {
                gain = min(gain + step, target)
            } else if gain > target {
                gain = max(gain - step, target)
            }
            let left = inLeft.samples[frame * inLeft.stride] * gain
            let right = inRight.samples[frame * inRight.stride] * gain
            if let outRight {
                outLeft.samples[frame * outLeft.stride] = left
                outRight.samples[frame * outRight.stride] = right
            } else {
                outLeft.samples[frame * outLeft.stride] = (left + right) * 0.5
            }
        }
        current = gain
    }

    private static func channel(_ list: UnsafeMutableAudioBufferListPointer, _ index: Int) -> Channel? {
        var remaining = index
        for buffer in list {
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else { continue }
            if remaining < channels {
                let frames = Int(buffer.mDataByteSize) / (MemoryLayout<Float>.size * channels)
                return (data.assumingMemoryBound(to: Float.self) + remaining, channels, frames)
            }
            remaining -= channels
        }
        return nil
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter RendererTests 2>&1 | grep -E "error|passed|failed" | tail -15`
Expected: 10 tests passed.

---

### Task 3: AppGrouping

**Files:**
- Create: `Sources/MixerCore/AppGrouping.swift`
- Test: `Tests/MixerCoreTests/AppGroupingTests.swift`

**Interfaces:**
- Produces:
  - `AudioProcess(objectID: UInt32, pid: pid_t, bundleID: String?, isRunningOutput: Bool)`
  - `ProcessTree(regularApps: [pid_t: String], responsible: (pid_t) -> pid_t?, parent: (pid_t) -> pid_t?)`
  - `AppGroup(id: String, objectIDs: [UInt32], isPlaying: Bool, isRegularApp: Bool)`
  - `AppGrouping.owner(of:in:) -> (id: String, isRegularApp: Bool)?`
  - `AppGrouping.group(_:in:excluding:) -> [AppGroup]` sorted by `id`, `objectIDs` sorted.

Resolution order: process is a regular app; responsible pid is a regular app; parent chain (max 16 hops, stops at pid 1); longest regular-app bundle ID that prefixes the process bundle ID at a `.` boundary; own bundle ID (`isRegularApp: false`); nil when there is no bundle ID.

- [ ] **Step 1: Write failing tests**

`Tests/MixerCoreTests/AppGroupingTests.swift`:

```swift
import Darwin
import Testing
@testable import MixerCore

struct AppGroupingTests {
    private func tree(
        regular: [pid_t: String],
        responsible: [pid_t: pid_t] = [:],
        parents: [pid_t: pid_t] = [:]
    ) -> ProcessTree {
        ProcessTree(regularApps: regular, responsible: { responsible[$0] }, parent: { parents[$0] })
    }

    private func process(_ objectID: UInt32, pid: pid_t, bundleID: String?, playing: Bool = false) -> AudioProcess {
        AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, isRunningOutput: playing)
    }

    @Test func regularAppOwnsItself() {
        let owner = AppGrouping.owner(of: process(1, pid: 10, bundleID: "com.apple.Music"), in: tree(regular: [10: "com.apple.Music"]))
        #expect(owner?.id == "com.apple.Music")
        #expect(owner?.isRegularApp == true)
    }

    @Test func responsiblePidWinsOverParent() {
        let tree = tree(regular: [10: "com.apple.Safari", 20: "com.example.Other"], responsible: [30: 10], parents: [30: 20])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.apple.WebKit.GPU"), in: tree)?.id == "com.apple.Safari")
    }

    @Test func walksParentChain() {
        let tree = tree(regular: [10: "com.google.Chrome"], parents: [30: 20, 20: 10])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.google.Chrome.helper"), in: tree)?.id == "com.google.Chrome")
    }

    @Test func parentCycleTerminates() {
        let tree = tree(regular: [:], parents: [30: 31, 31: 30])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: nil), in: tree) == nil)
    }

    @Test func stopsAtLaunchd() {
        let tree = tree(regular: [1: "bogus"], parents: [30: 1])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.example.daemon"), in: tree)?.id == "com.example.daemon")
    }

    @Test func prefixFallbackPicksLongestMatchAtDotBoundary() {
        let tree = tree(regular: [10: "com.example.App", 11: "com.example.App.Pro", 12: "com.example.Ap"])
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.example.App.Pro.helper"), in: tree)?.id == "com.example.App.Pro")
        #expect(AppGrouping.owner(of: process(2, pid: 31, bundleID: "com.example.App.helper"), in: tree)?.id == "com.example.App")
    }

    @Test func unknownProcessWithBundleIDOwnsItself() {
        let owner = AppGrouping.owner(of: process(1, pid: 30, bundleID: "com.example.daemon"), in: tree(regular: [:]))
        #expect(owner?.id == "com.example.daemon")
        #expect(owner?.isRegularApp == false)
    }

    @Test func processWithoutBundleIDOrOwnerIsSkipped() {
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: nil), in: tree(regular: [:])) == nil)
        #expect(AppGrouping.owner(of: process(1, pid: 30, bundleID: ""), in: tree(regular: [:])) == nil)
    }

    @Test func groupsHelpersUnderOneApp() {
        let tree = tree(regular: [10: "com.google.Chrome"], parents: [30: 10, 31: 10])
        let groups = AppGrouping.group([
            process(7, pid: 31, bundleID: "com.google.Chrome.helper", playing: true),
            process(5, pid: 30, bundleID: "com.google.Chrome.helper"),
            process(9, pid: 40, bundleID: nil),
        ], in: tree, excluding: 999)
        #expect(groups == [AppGroup(id: "com.google.Chrome", objectIDs: [5, 7], isPlaying: true, isRegularApp: true)])
    }

    @Test func excludesOwnProcess() {
        let tree = tree(regular: [10: "local.volumemixer.VolumeMixer"])
        #expect(AppGrouping.group([process(1, pid: 10, bundleID: "local.volumemixer.VolumeMixer")], in: tree, excluding: 10).isEmpty)
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter AppGroupingTests 2>&1 | grep -E "error|passed|failed" | head -10`
Expected: `cannot find 'ProcessTree' in scope`.

- [ ] **Step 3: Implement**

`Sources/MixerCore/AppGrouping.swift`:

```swift
import Darwin

public struct AudioProcess: Equatable, Sendable {
    public let objectID: UInt32
    public let pid: pid_t
    public let bundleID: String?
    public let isRunningOutput: Bool

    public init(objectID: UInt32, pid: pid_t, bundleID: String?, isRunningOutput: Bool) {
        self.objectID = objectID
        self.pid = pid
        self.bundleID = bundleID
        self.isRunningOutput = isRunningOutput
    }
}

public struct ProcessTree {
    /// pid to bundle ID, for apps with a regular activation policy.
    public var regularApps: [pid_t: String]
    public var responsible: (pid_t) -> pid_t?
    public var parent: (pid_t) -> pid_t?

    public init(regularApps: [pid_t: String], responsible: @escaping (pid_t) -> pid_t?, parent: @escaping (pid_t) -> pid_t?) {
        self.regularApps = regularApps
        self.responsible = responsible
        self.parent = parent
    }
}

public struct AppGroup: Equatable, Sendable {
    public let id: String
    public var objectIDs: [UInt32]
    public var isPlaying: Bool
    public var isRegularApp: Bool

    public init(id: String, objectIDs: [UInt32], isPlaying: Bool, isRegularApp: Bool) {
        self.id = id
        self.objectIDs = objectIDs
        self.isPlaying = isPlaying
        self.isRegularApp = isRegularApp
    }
}

public enum AppGrouping {
    public static func owner(of process: AudioProcess, in tree: ProcessTree) -> (id: String, isRegularApp: Bool)? {
        if let id = tree.regularApps[process.pid] { return (id, true) }
        if let responsible = tree.responsible(process.pid), let id = tree.regularApps[responsible] {
            return (id, true)
        }
        var pid = process.pid
        for _ in 0..<16 {
            guard let next = tree.parent(pid), next > 1, next != pid else { break }
            if let id = tree.regularApps[next] { return (id, true) }
            pid = next
        }
        guard let bundleID = process.bundleID, !bundleID.isEmpty else { return nil }
        let prefixMatch = tree.regularApps.values
            .filter { bundleID.hasPrefix($0 + ".") }
            .max { $0.count < $1.count }
        if let prefixMatch { return (prefixMatch, true) }
        return (bundleID, false)
    }

    public static func group(_ processes: [AudioProcess], in tree: ProcessTree, excluding selfPID: pid_t) -> [AppGroup] {
        var groups: [String: AppGroup] = [:]
        for process in processes where process.pid != selfPID {
            guard let owner = owner(of: process, in: tree) else { continue }
            var group = groups[owner.id] ?? AppGroup(id: owner.id, objectIDs: [], isPlaying: false, isRegularApp: owner.isRegularApp)
            group.objectIDs.append(process.objectID)
            group.isPlaying = group.isPlaying || process.isRunningOutput
            groups[owner.id] = group
        }
        return groups.values
            .map { group in
                var sorted = group
                sorted.objectIDs.sort()
                return sorted
            }
            .sorted { $0.id < $1.id }
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter AppGroupingTests 2>&1 | grep -E "error|passed|failed" | tail -15`
Expected: 10 tests passed.

---

### Task 4: MixerEngine

**Files:**
- Create: `Sources/MixerCore/MixerEngine.swift`
- Test: `Tests/MixerCoreTests/MixerEngineTests.swift`

**Interfaces:**
- Consumes: `VolumeStore`, `AppVolume`, `Gain.gain(for:)`, `AppGroup`.
- Produces:
  - `protocol VolumeControlling: AnyObject { func setGain(_ gain: Float); func invalidate() }`
  - `typealias ControllerFactory = (_ objectIDs: [UInt32], _ gain: Float) throws -> VolumeControlling`
  - `enum PermissionState { case unknown, granted, denied }`
  - `protocol PermissionProviding { var state: PermissionState { get }; func request(_ completion: @escaping (Bool) -> Void) }` — completion is called on the main thread.
  - `struct AppDescription { name: String; bundleURL: URL? }`
  - `MixerEngine(store:permissions:describe:factory:)`, `.rows`, `.permission`, `.update(groups:)`, `.setVolume(_:for:)`, `.setMuted(_:for:)`, `.outputDeviceChanged()`, `.refreshPermission()`
  - `MixerEngine.Row { id, name, bundleURL, isPlaying, isRunning, setting: AppVolume, failed }`

Rules:
- Controller exists for an app only when its volume is not default, it has process objects, and permission is granted.
- Same object IDs: `setGain`. Changed object IDs: invalidate and recreate.
- Factory throws: remember the failed object IDs, do not retry on periodic updates, do retry on `setVolume`, `setMuted`, object ID change, device change.
- Permission `.unknown`: request once; on answer set `.granted`/`.denied` and reconcile.
- Rows: groups that are regular apps or playing, plus every stored non-default bundle ID. Sort: playing, then running, then name.

- [ ] **Step 1: Write failing tests**

`Tests/MixerCoreTests/MixerEngineTests.swift`:

```swift
import Foundation
import Testing
@testable import MixerCore

final class FakeController: VolumeControlling {
    let objectIDs: [UInt32]
    var gains: [Float]
    var invalidated = false

    init(objectIDs: [UInt32], gain: Float) {
        self.objectIDs = objectIDs
        gains = [gain]
    }

    func setGain(_ gain: Float) { gains.append(gain) }
    func invalidate() { invalidated = true }
}

final class FakeFactory {
    struct Failure: Error {}
    var created: [FakeController] = []
    var failing: Set<[UInt32]> = []
    var attempts = 0

    func make(objectIDs: [UInt32], gain: Float) throws -> VolumeControlling {
        attempts += 1
        if failing.contains(objectIDs) { throw Failure() }
        let controller = FakeController(objectIDs: objectIDs, gain: gain)
        created.append(controller)
        return controller
    }

    var live: [FakeController] { created.filter { !$0.invalidated } }
}

final class FakePermissions: PermissionProviding {
    var state: PermissionState
    var requests = 0
    var pending: ((Bool) -> Void)?

    init(_ state: PermissionState) { self.state = state }

    func request(_ completion: @escaping (Bool) -> Void) {
        requests += 1
        pending = completion
    }
}

@MainActor
struct MixerEngineTests {
    let defaults = UserDefaults(suiteName: "MixerEngineTests-\(UUID().uuidString)")!
    let factory = FakeFactory()

    private func engine(_ permissions: FakePermissions = FakePermissions(.granted)) -> MixerEngine {
        MixerEngine(
            store: VolumeStore(defaults: defaults),
            permissions: permissions,
            describe: { AppDescription(name: $0.uppercased(), bundleURL: nil) },
            factory: factory.make)
    }

    private func group(_ id: String, _ objectIDs: [UInt32] = [1], playing: Bool = false, regular: Bool = true) -> AppGroup {
        AppGroup(id: id, objectIDs: objectIDs, isPlaying: playing, isRegularApp: regular)
    }

    @Test func fullVolumeCreatesNoController() {
        let engine = engine()
        engine.update(groups: [group("a")])
        #expect(factory.attempts == 0)
        #expect(engine.rows.map(\.id) == ["a"])
    }

    @Test func loweringVolumeCreatesControllerWithCurvedGain() {
        let engine = engine()
        engine.update(groups: [group("a", [3, 4])])
        engine.setVolume(0.5, for: "a")
        #expect(factory.created.count == 1)
        #expect(factory.created[0].objectIDs == [3, 4])
        #expect(factory.created[0].gains == [0.25])
        #expect(engine.rows[0].setting.volume == 0.5)
    }

    @Test func furtherChangesReuseController() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.1, for: "a")
        #expect(factory.created.count == 1)
        #expect(factory.created[0].gains.count == 2)
        #expect(abs(factory.created[0].gains[1] - 0.01) < 1e-6)
    }

    @Test func returningToFullVolumeInvalidates() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(1, for: "a")
        #expect(factory.created[0].invalidated)
        #expect(factory.live.isEmpty)
    }

    @Test func muteZeroesGainAndKeepsVolume() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.setMuted(true, for: "a")
        #expect(factory.created[0].gains.last == 0)
        #expect(engine.rows[0].setting == AppVolume(volume: 0.5, muted: true))
        engine.setMuted(false, for: "a")
        #expect(factory.created[0].gains.last == 0.25)
    }

    @Test func muteAtFullVolumeCreatesController() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setMuted(true, for: "a")
        #expect(factory.live.count == 1)
        #expect(factory.live[0].gains == [0])
    }

    @Test func savedVolumeAppliesWhenAppAppears() {
        VolumeStore(defaults: defaults).set(AppVolume(volume: 0.5), for: "a")
        let engine = engine()
        #expect(factory.attempts == 0)
        #expect(engine.rows.map(\.id) == ["a"])
        #expect(engine.rows[0].isRunning == false)
        engine.update(groups: [group("a")])
        #expect(factory.live.count == 1)
        #expect(engine.rows[0].isRunning)
    }

    @Test func appQuitInvalidatesAndKeepsDimmedRow() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.update(groups: [])
        #expect(factory.created[0].invalidated)
        #expect(engine.rows.map(\.id) == ["a"])
        #expect(engine.rows[0].isRunning == false)
    }

    @Test func changedProcessSetRebuildsController() {
        let engine = engine()
        engine.update(groups: [group("a", [1])])
        engine.setVolume(0.5, for: "a")
        engine.update(groups: [group("a", [1, 2])])
        #expect(factory.created.count == 2)
        #expect(factory.created[0].invalidated)
        #expect(factory.created[1].objectIDs == [1, 2])
    }

    @Test func unchangedUpdateDoesNotRebuild() {
        let engine = engine()
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        engine.update(groups: [group("a", playing: true)])
        #expect(factory.created.count == 1)
    }

    @Test func outputDeviceChangeRebuildsAll() {
        let engine = engine()
        engine.update(groups: [group("a", [1]), group("b", [2])])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.5, for: "b")
        engine.outputDeviceChanged()
        #expect(factory.created.count == 4)
        #expect(factory.live.count == 2)
    }

    @Test func failureFlagsOnlyThatRowAndRetriesOnUserChange() {
        let engine = engine()
        factory.failing = [[1]]
        engine.update(groups: [group("a", [1]), group("b", [2])])
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.5, for: "b")
        #expect(engine.rows.first { $0.id == "a" }?.failed == true)
        #expect(engine.rows.first { $0.id == "b" }?.failed == false)
        #expect(factory.live.map(\.objectIDs) == [[2]])

        let attempts = factory.attempts
        engine.update(groups: [group("a", [1], playing: true), group("b", [2])])
        #expect(factory.attempts == attempts)

        factory.failing = []
        engine.setVolume(0.4, for: "a")
        #expect(engine.rows.first { $0.id == "a" }?.failed == false)
        #expect(factory.live.count == 2)
    }

    @Test func deniedPermissionCreatesNothingUntilGranted() {
        let permissions = FakePermissions(.denied)
        let engine = engine(permissions)
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        #expect(factory.attempts == 0)
        #expect(engine.permission == .denied)
        #expect(permissions.requests == 0)

        permissions.state = .granted
        engine.refreshPermission()
        #expect(engine.permission == .granted)
        #expect(factory.live.count == 1)
    }

    @Test func unknownPermissionRequestsOnceThenApplies() {
        let permissions = FakePermissions(.unknown)
        let engine = engine(permissions)
        engine.update(groups: [group("a")])
        #expect(permissions.requests == 0)
        engine.setVolume(0.5, for: "a")
        engine.setVolume(0.4, for: "a")
        #expect(permissions.requests == 1)
        #expect(factory.attempts == 0)

        permissions.pending?(true)
        #expect(engine.permission == .granted)
        #expect(factory.live.count == 1)
    }

    @Test func refusedRequestMarksDenied() {
        let permissions = FakePermissions(.unknown)
        let engine = engine(permissions)
        engine.update(groups: [group("a")])
        engine.setVolume(0.5, for: "a")
        permissions.pending?(false)
        #expect(engine.permission == .denied)
        #expect(factory.attempts == 0)
    }

    @Test func rowsSortPlayingThenRunningThenName() {
        VolumeStore(defaults: defaults).set(AppVolume(volume: 0.5), for: "idle")
        let engine = engine()
        engine.update(groups: [group("zeta"), group("beta", [2], playing: true), group("alpha", [3])])
        #expect(engine.rows.map(\.id) == ["beta", "alpha", "zeta", "idle"])
    }

    @Test func silentBackgroundProcessIsHiddenButPlayingOneShows() {
        let engine = engine()
        engine.update(groups: [group("daemon", regular: false)])
        #expect(engine.rows.isEmpty)
        engine.update(groups: [group("daemon", playing: true, regular: false)])
        #expect(engine.rows.map(\.id) == ["daemon"])
    }
}
```

- [ ] **Step 2: Run, expect failure**

Run: `swift test --filter MixerEngineTests 2>&1 | grep -E "error|passed|failed" | head -10`
Expected: `cannot find type 'VolumeControlling' in scope`.

- [ ] **Step 3: Implement**

`Sources/MixerCore/MixerEngine.swift`:

```swift
import Foundation
import Observation

public protocol VolumeControlling: AnyObject {
    func setGain(_ gain: Float)
    func invalidate()
}

public typealias ControllerFactory = (_ objectIDs: [UInt32], _ gain: Float) throws -> VolumeControlling

public enum PermissionState: Sendable {
    case unknown, granted, denied
}

public protocol PermissionProviding {
    var state: PermissionState { get }
    /// Completion is called on the main thread.
    func request(_ completion: @escaping (Bool) -> Void)
}

public struct AppDescription: Equatable {
    public let name: String
    public let bundleURL: URL?

    public init(name: String, bundleURL: URL?) {
        self.name = name
        self.bundleURL = bundleURL
    }
}

@MainActor
@Observable
public final class MixerEngine {
    public struct Row: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let bundleURL: URL?
        public let isPlaying: Bool
        public let isRunning: Bool
        public let setting: AppVolume
        public let failed: Bool
    }

    public private(set) var rows: [Row] = []
    public private(set) var permission: PermissionState

    @ObservationIgnored private let store: VolumeStore
    @ObservationIgnored private let permissions: PermissionProviding
    @ObservationIgnored private let describe: (String) -> AppDescription
    @ObservationIgnored private let factory: ControllerFactory
    @ObservationIgnored private var groups: [String: AppGroup] = [:]
    @ObservationIgnored private var controllers: [String: (controller: VolumeControlling, objectIDs: [UInt32])] = [:]
    @ObservationIgnored private var failed: [String: [UInt32]] = [:]
    @ObservationIgnored private var requesting = false

    public init(
        store: VolumeStore,
        permissions: PermissionProviding,
        describe: @escaping (String) -> AppDescription,
        factory: @escaping ControllerFactory
    ) {
        self.store = store
        self.permissions = permissions
        self.describe = describe
        self.factory = factory
        permission = permissions.state
        reconcileAll()
    }

    public func update(groups newGroups: [AppGroup]) {
        groups = Dictionary(newGroups.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        reconcileAll()
    }

    public func setVolume(_ volume: Float, for id: String) {
        store.set(AppVolume(volume: volume, muted: store.volume(for: id).muted), for: id)
        userChanged(id)
    }

    public func setMuted(_ muted: Bool, for id: String) {
        store.set(AppVolume(volume: store.volume(for: id).volume, muted: muted), for: id)
        userChanged(id)
    }

    public func outputDeviceChanged() {
        for entry in controllers.values { entry.controller.invalidate() }
        controllers = [:]
        failed = [:]
        reconcileAll()
    }

    /// Picks up a grant or revocation made in System Settings.
    public func refreshPermission() {
        let current = permissions.state
        if current != .unknown, current != permission { permission = current }
        reconcileAll()
    }

    private func userChanged(_ id: String) {
        failed[id] = nil
        reconcile(id)
        rebuildRows()
    }

    private func reconcileAll() {
        for id in Set(groups.keys).union(controllers.keys).union(store.all.keys) {
            reconcile(id)
        }
        rebuildRows()
    }

    private func reconcile(_ id: String) {
        let setting = store.volume(for: id)
        let objectIDs = groups[id]?.objectIDs ?? []
        guard !setting.isDefault, !objectIDs.isEmpty else {
            drop(id)
            failed[id] = nil
            return
        }
        guard hasPermission() else {
            drop(id)
            return
        }
        let gain = Gain.gain(for: setting)
        if let existing = controllers[id], existing.objectIDs == objectIDs {
            existing.controller.setGain(gain)
            return
        }
        if failed[id] == objectIDs { return }
        drop(id)
        do {
            controllers[id] = (try factory(objectIDs, gain), objectIDs)
            failed[id] = nil
        } catch {
            failed[id] = objectIDs
        }
    }

    private func drop(_ id: String) {
        controllers.removeValue(forKey: id)?.controller.invalidate()
    }

    private func hasPermission() -> Bool {
        switch permission {
        case .granted:
            return true
        case .denied:
            return false
        case .unknown:
            if !requesting {
                requesting = true
                permissions.request { [weak self] granted in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.requesting = false
                        self.permission = granted ? .granted : .denied
                        self.reconcileAll()
                    }
                }
            }
            return false
        }
    }

    private func rebuildRows() {
        let visible = groups.values.filter { $0.isRegularApp || $0.isPlaying }.map(\.id)
        let ids = Set(visible).union(store.all.keys)
        let updated = ids.map { id -> Row in
            let description = describe(id)
            let group = groups[id]
            return Row(
                id: id,
                name: description.name,
                bundleURL: description.bundleURL,
                isPlaying: group?.isPlaying ?? false,
                isRunning: group != nil,
                setting: store.volume(for: id),
                failed: failed[id] != nil)
        }
        .sorted { first, second in
            if first.isPlaying != second.isPlaying { return first.isPlaying }
            if first.isRunning != second.isRunning { return first.isRunning }
            let order = first.name.localizedCaseInsensitiveCompare(second.name)
            return order == .orderedSame ? first.id < second.id : order == .orderedAscending
        }
        if updated != rows { rows = updated }
    }
}
```

- [ ] **Step 4: Run, expect pass**

Run: `swift test --filter MixerEngineTests 2>&1 | grep -E "error|passed|failed" | tail -22`
Expected: 17 tests passed.

---

### Task 5: Core Audio layer and login item

No unit tests: these wrap system services. Deliverable is a clean build of `MixerCore`; behavior is verified in Task 6.

**Files:**
- Create: `Sources/MixerCore/CoreAudioSupport.swift`, `Sources/MixerCore/AudioProcessMonitor.swift`, `Sources/MixerCore/TapVolumeController.swift`, `Sources/MixerCore/AudioCapturePermission.swift`, `Sources/MixerCore/LoginItem.swift`

**Interfaces:**
- Consumes: `AudioProcess`, `ProcessTree`, `AppGroup`, `AppGrouping.group`, `AppDescription`, `VolumeControlling`, `PermissionProviding`, `PermissionState`, `Renderer.process`, `Gain.rampStep`.
- Produces:
  - `AudioProcessMonitor()`, `.onChange: (([AppGroup]) -> Void)?`, `.onOutputDeviceChange: (() -> Void)?`, `.start()`. Callbacks arrive on the main thread.
  - `AppDescriber()`, `.describe(_ bundleID: String) -> AppDescription`
  - `TapVolumeController(objectIDs: [AudioObjectID], gain: Float) throws`, conforms to `VolumeControlling`
  - `AudioCapturePermission()`, conforms to `PermissionProviding`
  - `LoginItem.isEnabled: Bool`, `LoginItem.setEnabled(_:) throws`

Two private system interfaces are used, both resolved defensively: `responsibility_get_pid_responsible_for_pid` (maps Safari's WebKit processes to Safari) and TCC `TCCAccessPreflight` / `TCCAccessRequest` (no public API reports audio-capture permission). If the TCC symbols are missing the permission reports `.granted` and the system prompts by itself on first tap.

- [ ] **Step 1: Property helpers**

`Sources/MixerCore/CoreAudioSupport.swift`:

```swift
import CoreAudio
import Foundation

struct CoreAudioError: Error, CustomStringConvertible {
    let status: OSStatus
    let operation: String
    var description: String { "\(operation) failed: \(status)" }
}

func check(_ status: OSStatus, _ operation: String) throws {
    guard status == noErr else { throw CoreAudioError(status: status, operation: operation) }
}

func propertyAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
        mSelector: selector,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    func readValue<T>(_ selector: AudioObjectPropertySelector, initial: T) throws -> T {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<T>.size)
        var value = initial
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0)
        }
        try check(status, "read property \(selector)")
        return value
    }

    func readArray<T>(_ selector: AudioObjectPropertySelector, of type: T.Type) throws -> [T] {
        var address = propertyAddress(selector)
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size), "size of property \(selector)")
        let capacity = Int(size) / MemoryLayout<T>.stride
        guard capacity > 0 else { return [] }
        let buffer = UnsafeMutablePointer<T>.allocate(capacity: capacity)
        defer { buffer.deallocate() }
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, buffer), "read property \(selector)")
        return Array(UnsafeBufferPointer(start: buffer, count: Int(size) / MemoryLayout<T>.stride))
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(self, &address, 0, nil, &size, &value), "read property \(selector)")
        return (value?.takeRetainedValue() as String?) ?? ""
    }
}
```

- [ ] **Step 2: Process monitor and app describer**

`Sources/MixerCore/AudioProcessMonitor.swift`:

```swift
import AppKit
import CoreAudio

@_silgen_name("responsibility_get_pid_responsible_for_pid")
private func responsibility_get_pid_responsible_for_pid(_ pid: pid_t) -> pid_t

private func parentPID(of pid: pid_t) -> pid_t? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_eproc.e_ppid
}

/// Publishes the apps registered with the audio system. Callbacks arrive on the main thread.
public final class AudioProcessMonitor {
    public var onChange: (([AppGroup]) -> Void)?
    public var onOutputDeviceChange: (() -> Void)?

    private var timer: Timer?
    private var last: [AppGroup]?

    public init() {}

    public func start() {
        var processList = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(.system, &processList, .main) { [weak self] _, _ in
            self?.refresh()
        }
        var defaultOutput = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(.system, &defaultOutput, .main) { [weak self] _, _ in
            self?.onOutputDeviceChange?()
        }
        // The process list listener does not fire for play/pause, so poll for that.
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    public func refresh() {
        let groups = AppGrouping.group(readProcesses(), in: processTree(), excluding: getpid())
        guard groups != last else { return }
        last = groups
        onChange?(groups)
    }

    private func readProcesses() -> [AudioProcess] {
        let objectIDs = (try? AudioObjectID.system.readArray(kAudioHardwarePropertyProcessObjectList, of: AudioObjectID.self)) ?? []
        return objectIDs.compactMap { objectID in
            guard let pid = try? objectID.readValue(kAudioProcessPropertyPID, initial: pid_t(-1)), pid > 0 else { return nil }
            let bundleID = try? objectID.readString(kAudioProcessPropertyBundleID)
            let running = (try? objectID.readValue(kAudioProcessPropertyIsRunningOutput, initial: UInt32(0))) ?? 0
            return AudioProcess(objectID: objectID, pid: pid, bundleID: bundleID, isRunningOutput: running != 0)
        }
    }

    private func processTree() -> ProcessTree {
        var regular: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bundleID = app.bundleIdentifier { regular[app.processIdentifier] = bundleID }
        }
        return ProcessTree(
            regularApps: regular,
            responsible: { pid in
                let responsible = responsibility_get_pid_responsible_for_pid(pid)
                return responsible > 0 ? responsible : nil
            },
            parent: parentPID(of:))
    }
}

/// Resolves a bundle ID to a display name and bundle location.
public final class AppDescriber {
    private var cache: [String: AppDescription] = [:]

    public init() {}

    public func describe(_ bundleID: String) -> AppDescription {
        if let cached = cache[bundleID] { return cached }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        let url = running?.bundleURL ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        let name = running?.localizedName ?? url?.deletingPathExtension().lastPathComponent ?? bundleID
        let description = AppDescription(name: name, bundleURL: url)
        if url != nil { cache[bundleID] = description }
        return description
    }
}
```

- [ ] **Step 3: Tap controller**

`Sources/MixerCore/TapVolumeController.swift`:

```swift
import CoreAudio
import Foundation
import Synchronization

/// Shared with the IO thread. `target` is written from the main thread; the rest is IO-thread only.
private final class RenderState: @unchecked Sendable {
    let target: Atomic<UInt32>
    var current: Float
    var step: Float = 1

    init(gain: Float) {
        target = Atomic(gain.bitPattern)
        current = gain
    }
}

/// Mutes an app's own output and replays it on the default output device with a gain applied.
public final class TapVolumeController: VolumeControlling {
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let state: RenderState

    public init(objectIDs: [AudioObjectID], gain: Float) throws {
        state = RenderState(gain: gain)
        do {
            try start(objectIDs: objectIDs)
        } catch {
            invalidate()
            throw error
        }
    }

    deinit { invalidate() }

    public func setGain(_ gain: Float) {
        state.target.store(gain.bitPattern, ordering: .relaxed)
    }

    public func invalidate() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    private func start(objectIDs: [AudioObjectID]) throws {
        let tap = CATapDescription(stereoMixdownOfProcesses: objectIDs)
        tap.uuid = UUID()
        tap.muteBehavior = .mutedWhenTapped
        tap.isPrivate = true
        try check(AudioHardwareCreateProcessTap(tap, &tapID), "create process tap")

        let output = try AudioObjectID.system.readValue(
            kAudioHardwarePropertyDefaultOutputDevice, initial: AudioObjectID(kAudioObjectUnknown))
        let outputUID = try output.readString(kAudioDevicePropertyDeviceUID)
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "VolumeMixer Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: tap.uuid.uuidString,
            ]],
        ]
        try check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID), "create aggregate device")

        let sampleRate = (try? aggregateID.readValue(kAudioDevicePropertyNominalSampleRate, initial: Float64(48000))) ?? 48000
        state.step = Gain.rampStep(sampleRate: sampleRate)

        let state = self.state
        try check(AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, nil) { _, input, _, output, _ in
            let target = Float(bitPattern: state.target.load(ordering: .relaxed))
            Renderer.process(input: input, output: output, current: &state.current, target: target, step: state.step)
        }, "create IO proc")
        try check(AudioDeviceStart(aggregateID, ioProcID), "start device")
    }
}
```

- [ ] **Step 4: Permission and login item**

`Sources/MixerCore/AudioCapturePermission.swift`:

```swift
import Foundation

/// Audio-capture permission has no public query API; TCC's private preflight is the only way to
/// know the state before a tap silently delivers silence.
public final class AudioCapturePermission: PermissionProviding {
    private typealias Preflight = @convention(c) (CFString, CFDictionary?) -> Int
    private typealias Request = @convention(c) (CFString, CFDictionary?, @escaping @convention(block) (Bool) -> Void) -> Void

    private static let service = "kTCCServiceAudioCapture" as CFString
    private let preflight: Preflight?
    private let requestAccess: Request?

    public init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_NOW)
        preflight = handle.flatMap { dlsym($0, "TCCAccessPreflight") }.map { unsafeBitCast($0, to: Preflight.self) }
        requestAccess = handle.flatMap { dlsym($0, "TCCAccessRequest") }.map { unsafeBitCast($0, to: Request.self) }
    }

    public var state: PermissionState {
        guard let preflight else { return .granted }
        switch preflight(Self.service, nil) {
        case 0: return .granted
        case 1: return .denied
        default: return .unknown
        }
    }

    public func request(_ completion: @escaping (Bool) -> Void) {
        guard let requestAccess else {
            DispatchQueue.main.async { completion(true) }
            return
        }
        requestAccess(Self.service, nil) { granted in
            DispatchQueue.main.async { completion(granted) }
        }
    }
}
```

`Sources/MixerCore/LoginItem.swift`:

```swift
import ServiceManagement

public enum LoginItem {
    public static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    public static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
```

- [ ] **Step 5: Build**

Run: `swift build 2>&1 | grep -E "error|warning|Compiling|Build complete" | tail -20`
Expected: `Build complete!`, no errors.

- [ ] **Step 6: Rerun tests for sources touched since last green (none of the tested files changed, so only confirm the test target still links)**

Run: `swift build --build-tests 2>&1 | grep -E "error|Build complete" | tail -5`
Expected: `Build complete!`

---

### Task 6: App, bundle, manual verification

**Files:**
- Modify: `Package.swift` (add executable target)
- Create: `Sources/VolumeMixer/VolumeMixerApp.swift`, `Sources/VolumeMixer/MixerView.swift`, `Sources/VolumeMixer/AppRowView.swift`, `Resources/Info.plist`, `scripts/build.sh`, `scripts/install.sh`

**Interfaces:**
- Consumes: everything `public` from Tasks 1–5.

- [ ] **Step 1: Add executable target**

In `Package.swift`, targets become:

```swift
    targets: [
        .target(name: "MixerCore"),
        .executableTarget(name: "VolumeMixer", dependencies: ["MixerCore"]),
        .testTarget(name: "MixerCoreTests", dependencies: ["MixerCore"]),
    ],
```

- [ ] **Step 2: App entry and wiring**

`Sources/VolumeMixer/VolumeMixerApp.swift`:

```swift
import MixerCore
import SwiftUI

@MainActor
final class AppModel {
    let engine: MixerEngine
    private let monitor = AudioProcessMonitor()

    init() {
        // Dark only, whatever the system appearance is.
        NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
        let describer = AppDescriber()
        let engine = MixerEngine(
            store: VolumeStore(),
            permissions: AudioCapturePermission(),
            describe: describer.describe,
            factory: { try TapVolumeController(objectIDs: $0, gain: $1) })
        self.engine = engine
        monitor.onChange = { groups in
            MainActor.assumeIsolated { engine.update(groups: groups) }
        }
        monitor.onOutputDeviceChange = {
            MainActor.assumeIsolated { engine.outputDeviceChanged() }
        }
        monitor.start()
    }
}

@main
struct VolumeMixerApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Volume Mixer", systemImage: "slider.vertical.3") {
            MixerView(engine: model.engine)
        }
        .menuBarExtraStyle(.window)
    }
}
```

- [ ] **Step 3: Row view**

`Sources/VolumeMixer/AppRowView.swift`:

```swift
import MixerCore
import SwiftUI
import UniformTypeIdentifiers

struct AppRowView: View {
    let row: MixerEngine.Row
    let engine: MixerEngine

    private var icon: NSImage {
        if let url = row.bundleURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: .application)
    }

    private var percent: Int { Int((row.setting.volume * 100).rounded()) }

    var body: some View {
        HStack(spacing: 10) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 28, height: 28)
                .overlay(alignment: .bottomTrailing) {
                    if row.isPlaying {
                        Circle()
                            .fill(Color.accentColor)
                            .frame(width: 7, height: 7)
                            .overlay(Circle().stroke(.background, lineWidth: 1.5))
                    }
                }

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(row.name)
                        .font(.callout)
                        .lineLimit(1)
                    if row.failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.yellow)
                            .help("Could not control this app's audio. Move the slider to retry.")
                    }
                    Spacer(minLength: 4)
                    Text(row.setting.muted ? "Muted" : "\(percent)%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: Binding(
                        get: { Double(row.setting.volume) },
                        set: { engine.setVolume(Float($0), for: row.id) }),
                    in: 0...1)
                    .controlSize(.small)
                    .simultaneousGesture(TapGesture(count: 2).onEnded { engine.setVolume(1, for: row.id) })
                    .help("Double-click to reset to 100%")
            }

            Button {
                engine.setMuted(!row.setting.muted, for: row.id)
            } label: {
                Image(systemName: row.setting.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .frame(width: 20)
                    .foregroundStyle(row.setting.muted ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
            }
            .buttonStyle(.borderless)
            .help(row.setting.muted ? "Unmute" : "Mute")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .opacity(row.isRunning ? 1 : 0.5)
    }
}
```

- [ ] **Step 4: Popover view**

`Sources/VolumeMixer/MixerView.swift`:

```swift
import MixerCore
import SwiftUI

struct MixerView: View {
    let engine: MixerEngine
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Volume Mixer")
                .font(.headline)
                .padding(.horizontal, 12)
                .padding(.top, 12)
                .padding(.bottom, 6)

            if engine.permission == .denied {
                permissionBanner
            }

            if engine.rows.isEmpty {
                Text("No apps playing audio")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                VStack(spacing: 0) {
                    ForEach(engine.rows) { row in
                        AppRowView(row: row, engine: engine)
                    }
                }
                .disabled(engine.permission == .denied)
            }

            Divider()
                .padding(.top, 6)
            footer
        }
        .frame(width: 320)
        .preferredColorScheme(.dark)
        .animation(.snappy(duration: 0.2), value: engine.rows.map(\.id))
        .onAppear {
            engine.refreshPermission()
            launchAtLogin = LoginItem.isEnabled
        }
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Audio recording permission is off, so app volumes cannot be changed.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") {
                let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!
                NSWorkspace.shared.open(url)
            }
            .controlSize(.small)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.yellow.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle("Launch at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { enabled in
                        do {
                            try LoginItem.setEnabled(enabled)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                        }
                        launchAtLogin = LoginItem.isEnabled
                    }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
            if let loginError {
                Text(loginError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
```

- [ ] **Step 5: Info.plist**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>local.volumemixer.VolumeMixer</string>
    <key>CFBundleName</key>
    <string>Volume Mixer</string>
    <key>CFBundleExecutable</key>
    <string>VolumeMixer</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAudioCaptureUsageDescription</key>
    <string>Volume Mixer reads each app's audio so it can replay it at the volume you set.</string>
</dict>
</plist>
```

- [ ] **Step 6: Build and install scripts**

`scripts/build.sh`:

```bash
#!/bin/bash
# Builds build/VolumeMixer.app. Prints one summary line; full log path on failure.
set -euo pipefail
cd "$(dirname "$0")/.."

LOG=$(mktemp -t volumemixer-build)
if ! swift build -c release >"$LOG" 2>&1; then
    grep -E "error" "$LOG" | head -20
    echo "BUILD FAILED (log: $LOG)"
    exit 1
fi

APP=build/VolumeMixer.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/VolumeMixer "$APP/Contents/MacOS/"
cp Resources/Info.plist "$APP/Contents/"

# A real identity keeps the audio permission across rebuilds; ad-hoc signing resets it.
IDENTITY=$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ {print $2; exit}')
codesign --force --sign "${IDENTITY:--}" "$APP" 2>>"$LOG"

echo "OK $APP (signed: ${IDENTITY:-ad-hoc}, warnings: $(grep -c 'warning:' "$LOG" || true))"
```

`scripts/install.sh`:

```bash
#!/bin/bash
# Builds, installs to /Applications, relaunches.
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/build.sh
pkill -x VolumeMixer || true
rm -rf /Applications/VolumeMixer.app
cp -R build/VolumeMixer.app /Applications/
open /Applications/VolumeMixer.app
echo "Installed /Applications/VolumeMixer.app"
```

Then: `chmod +x scripts/build.sh scripts/install.sh`

- [ ] **Step 7: Build bundle**

Run: `./scripts/build.sh`
Expected: `OK build/VolumeMixer.app (signed: ..., warnings: N)`

Run: `codesign --verify --verbose build/VolumeMixer.app 2>&1 | tail -2`
Expected: `valid on disk`

- [ ] **Step 8: Install and verify by hand**

Run: `./scripts/install.sh`

Checklist (audio results need a person listening):
1. Slider icon appears in menu bar; no Dock icon. Popover is dark with system set to Light.
2. Play audio in two apps (for example Music and a browser video). Both rows listed with accent dot, sorted first.
3. Move one slider: permission prompt appears once; after Allow, that app gets quieter, the other is unchanged.
4. Mute button silences only that app; percent shows "Muted"; unmute restores previous level.
5. Double-click slider returns to 100%.
6. Switch output device (speakers to headphones): adjusted app stays at its level on the new device.
7. Quit and relaunch the adjusted app: volume reapplied. Quit and relaunch the mixer: sliders restored.
8. Quit the mixer: all apps return to full volume.
9. Launch at login on: Volume Mixer listed under System Settings, General, Login Items. Off: removed.
10. Revoke permission in Privacy & Security, System Audio Recording Only: banner appears on next popover open, sliders disabled.

---

## Unresolved Questions

1. No git repository. Want `git init` and a commit per task?
2. Two private system interfaces (TCC preflight, responsible pid). Fine for personal use; both have fallbacks. Keep?
3. Minimum raised to macOS 15 for `Synchronization.Atomic`. OK (you are on 26.5)?
