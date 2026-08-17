import Foundation
import CoreGraphics
import Shared

struct CaptureAppSnapshot: Sendable {
    let name: String?
    let bundleID: String?
    let pid: pid_t

    var logDescription: String {
        "\(Self.debugField(name)) [\(Self.debugField(bundleID))] pid=\(pid)"
    }

    func matches(bundleID otherBundleID: String?, appName otherAppName: String?) -> Bool {
        if let bundleID = Self.normalized(bundleID),
           let otherBundleID = Self.normalized(otherBundleID) {
            return bundleID == otherBundleID
        }

        if let name = Self.normalized(name),
           let otherAppName = Self.normalized(otherAppName) {
            return name == otherAppName
        }

        return false
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func debugField(_ value: String?) -> String {
        normalized(value) ?? "nil"
    }
}

enum WindowChangeEventSource: String, Sendable {
    case appActivation = "app_activation"
    case axActivation = "ax_activation"
}

struct WindowChangeEvent: Sendable {
    let id: UInt64
    let source: WindowChangeEventSource
    let observedAt: Date
    let activatedApp: CaptureAppSnapshot?
    let workspaceFrontmostApp: CaptureAppSnapshot?
}

private struct WindowChangeSignature: Sendable {
    let normalizedTitle: String?
    let normalizedBundleID: String?

    init(metadata: FrameMetadata) {
        self.normalizedTitle = Self.normalized(metadata.windowName)
        self.normalizedBundleID = Self.normalized(metadata.appBundleID)
    }

    private static func normalized(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}

/// Full-resolution dimensions of a captured frame.
struct FrameSize: Equatable, Sendable {
    let width: Int
    let height: Int
}

/// A captured frame that has not yet paid for its full-resolution pixel buffer.
///
/// Capturing a frame and building its BGRA buffer are separate steps because a large
/// share of captured frames are discarded before that buffer is ever read — first by
/// the window-change filter, then by deduplication. On the reference machine 37.4% of
/// captures (8,296 of 22,168 over 66.6h) were deduplicated, each having already
/// allocated and rendered a full 3440x1440 buffer of 19,814,400 bytes.
struct CaptureCandidate: Sendable {
    let timestamp: Date
    /// Full-resolution dimensions of the captured frame, not of `dedupProxy`.
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let metadata: FrameMetadata
    /// Small point-sampled reduction, sufficient for the deduplication comparison.
    let dedupProxy: CapturedFrame
}

protocol ScreenCaptureBackend: Actor {
    func startCapture(config: CaptureConfig, displayID: CGDirectDisplayID?) async throws
    func stopCapture() async throws
    func updateConfig(_ config: CaptureConfig) async throws

    /// Captures a frame without building its full-resolution buffer. The backend
    /// retains the underlying image until `materializePendingFrame()` or
    /// `discardPendingCapture()` is called, or until the next `captureCandidate` call.
    func captureCandidate(displayID: CGDirectDisplayID) async -> CaptureCandidate?
    /// Builds the full-resolution frame for the pending candidate.
    func materializePendingFrame() async -> CapturedFrame?
    /// Releases the pending candidate without building its buffer.
    func discardPendingCapture() async
}

protocol CaptureDisplayMonitoring: Actor {
    func getAvailableDisplays() async throws -> [DisplayInfo]
    func getFocusedDisplay() async throws -> DisplayInfo?
    func getActiveDisplayID() -> UInt32
    func getActiveDisplayIDWithPermissionStatus() -> (UInt32, Bool)
}

protocol CaptureDisplaySwitchMonitoring: Actor {
    func setOnDisplaySwitch(_ callback: (@Sendable (UInt32, UInt32) async -> Void)?)
    func setOnAccessibilityPermissionDenied(_ callback: (@Sendable () async -> Void)?)
    func setOnWindowChange(_ callback: (@Sendable (WindowChangeEvent) async -> Void)?)
    func startMonitoring(initialDisplayID: UInt32)
    func stopMonitoring() async
}

protocol CaptureMouseClickMonitoring: Actor {
    func setOnLeftMouseUp(_ callback: (@Sendable () async -> Void)?)
    func startMonitoring() async -> Bool
    func stopMonitoring() async
}

protocol CaptureAppInfoProviding: Sendable {
    func getFrontmostAppInfo(
        includeBrowserURL: Bool,
        preferredDisplayID: CGDirectDisplayID?
    ) async -> FrameMetadata
}

struct CaptureSchedulingConfiguration: Sendable {
    let minimumInterCaptureInterval: TimeInterval
    let mouseClickSettleDelay: TimeInterval
    let windowChangeSettleDelay: TimeInterval
    let startWithImmediateIntervalCapture: Bool

    static let production = CaptureSchedulingConfiguration(
        minimumInterCaptureInterval: 0.3,
        mouseClickSettleDelay: 0.15,
        windowChangeSettleDelay: 0.15,
        startWithImmediateIntervalCapture: true
    )
}

public enum MouseClickCaptureOutcome: String, Sendable {
    case captured
    case debounced
    case superseded
    case monitorUnavailable = "monitor_unavailable"
    case deduped
}

/// Main coordinator for screen capture
/// Implements CaptureProtocol from Shared/Protocols
public actor CaptureManager: CaptureProtocol {
    private static let automaticTriggerConfigurationErrorReason =
        "At least one automatic capture trigger must be enabled."
    private static let activationAgreementTimeout: TimeInterval = 0.15

    private enum CaptureTrigger: Sendable, Equatable {
        case mouseClick
        case windowChange
        case interval

        var priority: Int {
            switch self {
            case .mouseClick: return 3
            case .windowChange: return 2
            case .interval: return 1
            }
        }

        func settleDelay(using configuration: CaptureSchedulingConfiguration) -> TimeInterval {
            switch self {
            case .mouseClick:
                return configuration.mouseClickSettleDelay
            case .windowChange:
                return configuration.windowChangeSettleDelay
            case .interval:
                return 0
            }
        }

    }

    private struct PendingCapture: Sendable {
        let trigger: CaptureTrigger
        let fireTime: Date
        let windowChangeEvent: WindowChangeEvent?
        let windowChangeSignature: WindowChangeSignature?
    }

    private let cgWindowListCapture: any ScreenCaptureBackend
    private let displayMonitor: any CaptureDisplayMonitoring
    private let displaySwitchMonitor: any CaptureDisplaySwitchMonitoring
    private let mouseClickMonitor: any CaptureMouseClickMonitoring
    private let deduplicator: FrameDeduplicator
    private let appInfoProvider: any CaptureAppInfoProviding
    private let schedulingConfiguration: CaptureSchedulingConfiguration
    private let now: @Sendable () -> Date

    private var currentConfig: CaptureConfig
    /// Deduplication reference. Only the small proxy of the last kept frame is
    /// retained, not its full-resolution buffer — the comparison never needed the
    /// full buffer, and holding it pinned ~19.8 MB for the life of the capture session.
    private var lastKeptProxy: CapturedFrame?
    /// Full-resolution dimensions of the last kept frame. Tracked separately because
    /// `lastKeptProxy` is the reduced grid, so a resolution change at the same aspect
    /// ratio would be invisible in the proxy's own dimensions.
    private var lastKeptFrameSize: FrameSize?
    private var lastKeptMousePosition: CGPoint?
    private var _isCapturing = false

    private var dedupedFrameContinuation: AsyncStream<CapturedFrame>.Continuation?
    private var _frameStream: AsyncStream<CapturedFrame>?

    private var stats = CaptureStatistics(
        totalFramesCaptured: 0,
        framesDeduped: 0,
        averageFrameSizeBytes: 0,
        captureStartTime: nil,
        lastFrameTime: nil
    )
    private var totalCapturedBytes: Int64 = 0

    private var hasShownAccessibilityWarning = false
    private var hasReportedMouseMonitorUnavailable = false
    private var mouseClickMonitoringNeedsRetry = false

    private var lastAcceptedWindowChangeSignature: WindowChangeSignature?
    private var isWindowChangeEvaluationInFlight = false
    private var latestWindowChangeEvent: WindowChangeEvent?
    private var deferredDisplaySyncTask: Task<Void, Never>?
    private var scheduledCaptureTask: Task<Void, Never>?
    private var pendingCapture: PendingCapture?
    private var lastActualCaptureTime: Date?
    private var currentCaptureDisplayID: UInt32?
    private var isCaptureExecutionInFlight = false
    private static let dedupedFrameBufferLimit = 8
    private static let memoryLedgerCurrentFrameTag = "capture.stream.currentFrame"
    private static let memoryLedgerLastKeptFrameTag = "capture.dedup.lastKeptFrame"
    private static let memoryLedgerSummaryIntervalSeconds: TimeInterval = 5

    nonisolated(unsafe) public var onAccessibilityPermissionWarning: (() -> Void)?
    nonisolated(unsafe) public var onCaptureStopped: (@Sendable () async -> Void)?
    nonisolated(unsafe) public var onCaptureObserved: (@Sendable (Date, String) async -> Void)?
    nonisolated(unsafe) public var onMouseClickCaptureOutcome: (@Sendable (MouseClickCaptureOutcome, Date) async -> Void)?

    public init(config: CaptureConfig = .default) {
        let displayMonitor = DisplayMonitor()
        self.currentConfig = config
        self.cgWindowListCapture = CGWindowListCapture()
        self.displayMonitor = displayMonitor
        self.displaySwitchMonitor = DisplaySwitchMonitor(displayMonitor: displayMonitor)
        self.mouseClickMonitor = MouseClickMonitor()
        self.deduplicator = FrameDeduplicator()
        self.appInfoProvider = AppInfoProvider()
        self.schedulingConfiguration = .production
        self.now = { Date() }
    }

    init(
        config: CaptureConfig,
        cgWindowListCapture: any ScreenCaptureBackend,
        displayMonitor: any CaptureDisplayMonitoring,
        displaySwitchMonitor: any CaptureDisplaySwitchMonitoring,
        mouseClickMonitor: any CaptureMouseClickMonitoring,
        deduplicator: FrameDeduplicator = FrameDeduplicator(),
        appInfoProvider: any CaptureAppInfoProviding = AppInfoProvider(),
        schedulingConfiguration: CaptureSchedulingConfiguration = .production,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.currentConfig = config
        self.cgWindowListCapture = cgWindowListCapture
        self.displayMonitor = displayMonitor
        self.displaySwitchMonitor = displaySwitchMonitor
        self.mouseClickMonitor = mouseClickMonitor
        self.deduplicator = deduplicator
        self.appInfoProvider = appInfoProvider
        self.schedulingConfiguration = schedulingConfiguration
        self.now = now
    }

    public func hasPermission() async -> Bool {
        await PermissionChecker.hasScreenRecordingPermission()
    }

    public func requestPermission() async -> Bool {
        await PermissionChecker.requestPermission()
    }

    public func startCapture(config: CaptureConfig) async throws {
        guard !_isCapturing else { return }
        try validateCaptureConfiguration(config)

        guard await hasPermission() else {
            throw CaptureError.permissionDenied
        }

        self.currentConfig = config

        let (dedupedStream, dedupedContinuation) = AsyncStream<CapturedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.dedupedFrameBufferLimit)
        )
        self.dedupedFrameContinuation = dedupedContinuation
        self._frameStream = dedupedStream

        let activeDisplayID = await displayMonitor.getActiveDisplayID()
        currentCaptureDisplayID = activeDisplayID

        try await cgWindowListCapture.startCapture(
            config: config,
            displayID: activeDisplayID
        )

        _isCapturing = true
        resetCaptureState()

        await startDisplaySwitchMonitoring(initialDisplayID: activeDisplayID)
        await configureMouseClickMonitoring(enabled: config.captureOnMouseClick)

        if intervalCaptureEnabled(), schedulingConfiguration.startWithImmediateIntervalCapture {
            enqueueCapture(trigger: .interval, requestedAt: now())
        } else if intervalCaptureEnabled() {
            scheduleNextIntervalCapture(from: now())
        }
    }

    public func stopCapture() async throws {
        guard _isCapturing else { return }

        _isCapturing = false

        scheduledCaptureTask?.cancel()
        scheduledCaptureTask = nil
        isWindowChangeEvaluationInFlight = false
        latestWindowChangeEvent = nil
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = nil
        pendingCapture = nil

        await displaySwitchMonitor.stopMonitoring()
        await mouseClickMonitor.stopMonitoring()
        try await cgWindowListCapture.stopCapture()

        dedupedFrameContinuation?.finish()
        dedupedFrameContinuation = nil
        _frameStream = nil

        lastKeptProxy = nil
        lastKeptFrameSize = nil
        lastKeptMousePosition = nil
        lastAcceptedWindowChangeSignature = nil
        updateCaptureMemoryLedger(currentFrameBytes: 0)
        currentCaptureDisplayID = nil
        lastActualCaptureTime = nil
        totalCapturedBytes = 0
        hasShownAccessibilityWarning = false
        hasReportedMouseMonitorUnavailable = false
        isCaptureExecutionInFlight = false
    }

    public var isCapturing: Bool {
        _isCapturing
    }

    public var frameStream: AsyncStream<CapturedFrame> {
        if let stream = _frameStream {
            return stream
        }

        let (stream, continuation) = AsyncStream<CapturedFrame>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.dedupedFrameBufferLimit)
        )
        self.dedupedFrameContinuation = continuation
        self._frameStream = stream
        return stream
    }

    public func updateConfig(_ config: CaptureConfig) async throws {
        try await applyConfigUpdate(config)
    }

    public func updateConfig(
        _ transform: @Sendable (CaptureConfig) -> CaptureConfig
    ) async throws {
        try await applyConfigUpdate(transform(currentConfig))
    }

    private func applyConfigUpdate(_ config: CaptureConfig) async throws {
        try validateCaptureConfiguration(config)
        currentConfig = config

        if _isCapturing {
            try await cgWindowListCapture.updateConfig(config)
            await configureMouseClickMonitoring(enabled: config.captureOnMouseClick)
            cancelDisabledPendingRequestIfNeeded()
            scheduleNextIntervalCapture(from: lastActualCaptureTime ?? now())
        }
    }

    public func getConfig() async -> CaptureConfig { currentConfig }

    public func getAvailableDisplays() async throws -> [DisplayInfo] {
        try await displayMonitor.getAvailableDisplays()
    }

    public func getFocusedDisplay() async throws -> DisplayInfo? {
        try await displayMonitor.getFocusedDisplay()
    }

    public func getStatistics() -> CaptureStatistics {
        stats
    }

    private func validateCaptureConfiguration(_ config: CaptureConfig) throws {
        guard config.captureIntervalSeconds > 0 || config.captureOnWindowChange || config.captureOnMouseClick else {
            throw CaptureError.invalidConfiguration(
                reason: Self.automaticTriggerConfigurationErrorReason
            )
        }
    }

    private func resetCaptureState() {
        scheduledCaptureTask?.cancel()
        scheduledCaptureTask = nil
        pendingCapture = nil
        isWindowChangeEvaluationInFlight = false
        latestWindowChangeEvent = nil
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = nil
        lastKeptProxy = nil
        lastKeptFrameSize = nil
        lastKeptMousePosition = nil
        lastAcceptedWindowChangeSignature = nil
        updateCaptureMemoryLedger(currentFrameBytes: 0)
        totalCapturedBytes = 0
        lastActualCaptureTime = nil
        hasShownAccessibilityWarning = false
        hasReportedMouseMonitorUnavailable = false
        mouseClickMonitoringNeedsRetry = false
        isCaptureExecutionInFlight = false
        stats = CaptureStatistics(
            totalFramesCaptured: 0,
            framesDeduped: 0,
            averageFrameSizeBytes: 0,
            captureStartTime: now(),
            lastFrameTime: nil
        )
    }

    private func startDisplaySwitchMonitoring(initialDisplayID: UInt32) async {
        await displaySwitchMonitor.setOnDisplaySwitch { [weak self] oldDisplayID, newDisplayID in
            await self?.handleDisplaySwitch(from: oldDisplayID, to: newDisplayID)
        }
        await displaySwitchMonitor.setOnAccessibilityPermissionDenied { [weak self] in
            await self?.handleAccessibilityPermissionDenied()
        }
        await displaySwitchMonitor.setOnWindowChange { [weak self] event in
            await self?.handleWindowChange(event)
        }
        await displaySwitchMonitor.startMonitoring(initialDisplayID: initialDisplayID)
    }

    private func configureMouseClickMonitoring(enabled: Bool) async {
        if enabled && _isCapturing {
            await mouseClickMonitor.setOnLeftMouseUp { [weak self] in
                await self?.handleMouseClick()
            }
            let hasFullCoverage = await mouseClickMonitor.startMonitoring()
            if hasFullCoverage {
                hasReportedMouseMonitorUnavailable = false
                mouseClickMonitoringNeedsRetry = false
            } else if !hasReportedMouseMonitorUnavailable {
                mouseClickMonitoringNeedsRetry = true
                hasReportedMouseMonitorUnavailable = true
                reportMouseClickOutcome(.monitorUnavailable)
            } else {
                mouseClickMonitoringNeedsRetry = true
            }
        } else {
            await mouseClickMonitor.setOnLeftMouseUp(nil)
            await mouseClickMonitor.stopMonitoring()
            hasReportedMouseMonitorUnavailable = false
            mouseClickMonitoringNeedsRetry = false
        }
    }

    public func retryMouseClickMonitoringIfNeeded() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnMouseClick else { return }
        guard mouseClickMonitoringNeedsRetry else { return }

        await configureMouseClickMonitoring(enabled: true)
    }

    public func suspendMouseClickMonitoringForPermissionLoss() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnMouseClick else { return }

        mouseClickMonitoringNeedsRetry = true
        await mouseClickMonitor.stopMonitoring()
    }

    private func handleMouseClick() async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnMouseClick else { return }

        enqueueCapture(trigger: .mouseClick, requestedAt: now())
    }

    private func handleWindowChange(_ event: WindowChangeEvent) async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        latestWindowChangeEvent = event

        guard !isWindowChangeEvaluationInFlight else {
            return
        }

        isWindowChangeEvaluationInFlight = true
        defer {
            isWindowChangeEvaluationInFlight = false
        }

        while let eventToEvaluate = latestWindowChangeEvent {
            latestWindowChangeEvent = nil
            await evaluateWindowChange(eventToEvaluate)
        }
    }

    private func evaluateWindowChange(_ event: WindowChangeEvent) async {
        guard _isCapturing else { return }
        guard currentConfig.captureOnWindowChange else { return }

        await syncCaptureDisplayIfNeeded()
        guard !hasQueuedNewerWindowChangeEvent(overriding: event) else { return }

        let currentMetadata = await appInfoProvider.getFrontmostAppInfo(
            includeBrowserURL: false,
            preferredDisplayID: nil
        )
        guard _isCapturing else { return }
        guard !hasQueuedNewerWindowChangeEvent(overriding: event) else { return }

        let decisionMetadata: FrameMetadata
        switch event.source {
        case .appActivation:
            let expectedApp = event.activatedApp ?? event.workspaceFrontmostApp
            let matchesExpected = expectedApp.map {
                $0.matches(bundleID: currentMetadata.appBundleID, appName: currentMetadata.appName)
            } ?? true

            if let expectedApp, !matchesExpected {
                let maxWaitSeconds = Self.activationAgreementTimeout
                let deadline = now().addingTimeInterval(maxWaitSeconds)
                let pollInterval = max(0.01, min(0.05, maxWaitSeconds / 6))
                guard let agreedMetadata = await waitForExpectedAppMatch(
                    expectedApp,
                    pollInterval: pollInterval,
                    deadline: deadline,
                    supersededBy: event
                ) else {
                    return
                }
                guard _isCapturing else { return }
                guard !hasQueuedNewerWindowChangeEvent(overriding: event) else { return }
                decisionMetadata = agreedMetadata
            } else {
                decisionMetadata = currentMetadata
            }
        case .axActivation:
            decisionMetadata = currentMetadata
        }

        let decisionSignature = WindowChangeSignature(metadata: decisionMetadata)
        guard !shouldSuppressWindowChangeCapture(for: decisionSignature) else {
            return
        }
        guard !hasQueuedNewerWindowChangeEvent(overriding: event) else { return }

        if event.source == .appActivation {
            enqueueCapture(
                trigger: .windowChange,
                fireTime: now(),
                windowChangeEvent: event,
                windowChangeSignature: decisionSignature
            )
        } else {
            enqueueCapture(
                trigger: .windowChange,
                requestedAt: now(),
                windowChangeEvent: event,
                windowChangeSignature: decisionSignature
            )
        }
    }

    private func enqueueCapture(
        trigger: CaptureTrigger,
        requestedAt: Date,
        windowChangeEvent: WindowChangeEvent? = nil,
        windowChangeSignature: WindowChangeSignature? = nil
    ) {
        let fireTime = requestedAt.addingTimeInterval(
            trigger.settleDelay(using: schedulingConfiguration)
        )
        enqueueCapture(
            trigger: trigger,
            fireTime: fireTime,
            windowChangeEvent: windowChangeEvent,
            windowChangeSignature: windowChangeSignature
        )
    }

    private func enqueueCapture(
        trigger: CaptureTrigger,
        fireTime: Date,
        windowChangeEvent: WindowChangeEvent? = nil,
        windowChangeSignature: WindowChangeSignature? = nil
    ) {
        let capture = PendingCapture(
            trigger: trigger,
            fireTime: fireTime,
            windowChangeEvent: windowChangeEvent,
            windowChangeSignature: windowChangeSignature
        )
        enqueueCapture(capture)
    }

    private func enqueueCapture(
        _ capture: PendingCapture,
        bypassRefractoryDrop: Bool = false
    ) {
        guard _isCapturing else { return }
        guard !shouldDropRequestDuringRefractory(
            capture,
            bypassRefractoryDrop: bypassRefractoryDrop
        ) else {
            if capture.trigger == .mouseClick {
                reportMouseClickOutcome(.debounced)
            }
            return
        }

        if let existing = pendingCapture {
            guard shouldReplacePendingCapture(existing: existing, with: capture) else {
                return
            }

            if existing.trigger == .mouseClick {
                reportMouseClickOutcome(.superseded)
            }
        }

        pendingCapture = capture
        reschedulePendingCaptureTask()
    }

    private func shouldReplacePendingCapture(
        existing: PendingCapture,
        with incoming: PendingCapture
    ) -> Bool {
        if incoming.trigger.priority > existing.trigger.priority {
            return true
        }
        if incoming.trigger.priority < existing.trigger.priority {
            return false
        }
        return incoming.fireTime >= existing.fireTime
    }

    private func reschedulePendingCaptureTask() {
        scheduledCaptureTask?.cancel()
        scheduledCaptureTask = nil

        guard let capture = pendingCapture else { return }

        scheduledCaptureTask = Task { [weak self] in
            guard let self else { return }

            let delay = capture.fireTime.timeIntervalSince(self.now())
            if delay > 0 {
                try? await Task.sleep(for: Self.sleepDuration(seconds: delay), clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            await self.executePendingCapture()
        }
    }

    private func executePendingCapture() async {
        guard let capture = pendingCapture else { return }
        guard !isCaptureExecutionInFlight else { return }

        pendingCapture = nil
        scheduledCaptureTask = nil
        isCaptureExecutionInFlight = true
        defer {
            isCaptureExecutionInFlight = false
            if _isCapturing {
                reschedulePendingCaptureTask()
            }
        }

        if capture.trigger == .windowChange {
            await syncCaptureDisplayIfNeeded()
        }

        let captureAttemptStartedAt = now()
        let displayID = await displayIDForCapture(trigger: capture.trigger)
        currentCaptureDisplayID = displayID

        let candidate = await cgWindowListCapture.captureCandidate(displayID: displayID)
        let captureAttemptCompletedAt = now()
        if let candidate {
            lastActualCaptureTime = captureAttemptCompletedAt
            if let windowChangeEvent = capture.windowChangeEvent {
                let shouldDropFrame = shouldDropWindowChangeCapture(
                    event: windowChangeEvent,
                    capturedMetadata: candidate.metadata
                )
                if shouldDropFrame {
                    // Dropped on metadata alone, before the full-resolution buffer
                    // was ever built.
                    await cgWindowListCapture.discardPendingCapture()
                    scheduleNextIntervalCapture(from: captureAttemptCompletedAt)
                    if capture.trigger == .windowChange {
                        await syncCaptureDisplayIfNeeded()
                        scheduleDisplaySyncCheck()
                    }
                    return
                }
            }
            if let windowChangeSignature = capture.windowChangeSignature {
                lastAcceptedWindowChangeSignature = windowChangeSignature
            }
            await handleCapturedCandidate(candidate, trigger: capture.trigger)
            scheduleNextIntervalCapture(from: captureAttemptCompletedAt)
        } else {
            scheduleNextIntervalCapture(from: max(captureAttemptStartedAt, captureAttemptCompletedAt))
        }

        if capture.trigger == .windowChange {
            await syncCaptureDisplayIfNeeded()
            scheduleDisplaySyncCheck()
        }
    }

    private func displayIDForCapture(trigger: CaptureTrigger) async -> UInt32 {
        switch trigger {
        case .mouseClick:
            let (activeDisplayID, hasPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
            if hasPermission {
                return activeDisplayID
            }
            if let currentCaptureDisplayID {
                return currentCaptureDisplayID
            }
            return activeDisplayID
        case .windowChange, .interval:
            if let currentCaptureDisplayID {
                return currentCaptureDisplayID
            }
            return await displayMonitor.getActiveDisplayID()
        }
    }

    private func scheduleNextIntervalCapture(from referenceTime: Date) {
        guard _isCapturing else { return }
        guard intervalCaptureEnabled() else { return }

        let capture = PendingCapture(
            trigger: .interval,
            fireTime: referenceTime.addingTimeInterval(currentConfig.captureIntervalSeconds),
            windowChangeEvent: nil,
            windowChangeSignature: nil
        )
        enqueueCapture(capture, bypassRefractoryDrop: true)
    }

    private func waitForExpectedAppMatch(
        _ expectedApp: CaptureAppSnapshot,
        pollInterval: TimeInterval,
        deadline: Date,
        supersededBy event: WindowChangeEvent
    ) async -> FrameMetadata? {
        while now() < deadline {
            if hasQueuedNewerWindowChangeEvent(overriding: event) {
                return nil
            }
            if Task.isCancelled { return nil }
            let metadata = await appInfoProvider.getFrontmostAppInfo(
                includeBrowserURL: false,
                preferredDisplayID: nil
            )
            if hasQueuedNewerWindowChangeEvent(overriding: event) {
                return nil
            }
            if expectedApp.matches(bundleID: metadata.appBundleID, appName: metadata.appName) {
                return metadata
            }
            let remaining = deadline.timeIntervalSince(now())
            let sleepSeconds = min(pollInterval, max(remaining, 0))
            if sleepSeconds > 0 {
                try? await Task.sleep(for: Self.sleepDuration(seconds: sleepSeconds), clock: .continuous)
            }
        }
        return nil
    }

    private func shouldDropRequestDuringRefractory(
        _ capture: PendingCapture,
        bypassRefractoryDrop: Bool = false
    ) -> Bool {
        guard bypassRefractoryDrop || !isCaptureExecutionInFlight else {
            return true
        }
        guard let lastActualCaptureTime else {
            return false
        }

        let refractoryEndsAt = lastActualCaptureTime.addingTimeInterval(
            schedulingConfiguration.minimumInterCaptureInterval
        )
        return capture.fireTime < refractoryEndsAt
    }

    private func cancelDisabledPendingRequestIfNeeded() {
        guard let pendingCapture else { return }

        let shouldCancel: Bool
        switch pendingCapture.trigger {
        case .mouseClick:
            shouldCancel = !currentConfig.captureOnMouseClick
        case .windowChange:
            shouldCancel = !currentConfig.captureOnWindowChange
        case .interval:
            shouldCancel = !intervalCaptureEnabled()
        }

        guard shouldCancel else { return }
        self.pendingCapture = nil
        reschedulePendingCaptureTask()
    }

    private func intervalCaptureEnabled() -> Bool {
        currentConfig.captureIntervalSeconds > 0
    }

    private func handleDisplaySwitch(from oldDisplayID: UInt32, to newDisplayID: UInt32) async {
        await MainActor.run {
            NotificationCenter.default.post(
                name: .activeDisplayDidChange,
                object: nil,
                userInfo: ["displayID": newDisplayID]
            )
        }

        guard _isCapturing else { return }
        guard oldDisplayID != newDisplayID else {
            currentCaptureDisplayID = newDisplayID
            return
        }

        currentCaptureDisplayID = newDisplayID
    }

    private func handleAccessibilityPermissionDenied() async {
        guard !hasShownAccessibilityWarning else { return }
        hasShownAccessibilityWarning = true
        onAccessibilityPermissionWarning?()
    }

    private func handleCapturedCandidate(
        _ candidate: CaptureCandidate,
        trigger: CaptureTrigger
    ) async {
        // The full-resolution buffer does not exist yet. Its size is exactly
        // bytesPerRow * height, which is what imageData.count used to report here.
        //
        // Deliberately NOT reported to the memory ledger up front: for a frame that is
        // about to be deduplicated the buffer is never built, so claiming it here would
        // report ~19.8 MB of resident frame that this change exists to avoid. The
        // ledger is updated once the buffer actually exists, after materialization.
        let estimatedFrameBytes = Int64(candidate.bytesPerRow) * Int64(candidate.height)
        defer {
            updateCaptureMemoryLedger(currentFrameBytes: 0)
        }

        let triggerDescription = Self.triggerLogDescription(for: trigger)
        reportCaptureObserved(trigger: trigger, timestamp: candidate.timestamp)
        totalCapturedBytes += estimatedFrameBytes
        let totalFrames = stats.totalFramesCaptured + 1
        let currentMousePosition = currentConfig.keepFramesOnMouseMovement
            ? Self.mousePositionWithinCapturedFrame(
                width: candidate.width,
                height: candidate.height,
                displayID: candidate.metadata.displayID
            )
            : nil

        if currentConfig.adaptiveCaptureEnabled {
            // Run the similarity scan once and derive the keep decision from the
            // result. shouldKeepFrame would otherwise repeat the identical full
            // sampling scan, so the always-on capture path paid for it twice per
            // frame: once for the log line below, once for the decision.
            //
            // The scan runs against the small proxies rather than the full-resolution
            // buffers: the proxy is the sampling grid the comparison would have read.
            let similarity = lastKeptProxy.map {
                deduplicator.computeSimilarity(candidate.dedupProxy, $0)
            }
            let keepBySimilarity = Self.shouldKeepFrameForSimilarity(
                frameSize: FrameSize(width: candidate.width, height: candidate.height),
                referenceSize: lastKeptFrameSize,
                similarity: similarity,
                threshold: currentConfig.deduplicationThreshold
            )
            let keepByMouseMovement = Self.shouldKeepFrameForMouseMovement(
                enabled: currentConfig.keepFramesOnMouseMovement,
                previousMousePosition: lastKeptMousePosition,
                currentMousePosition: currentMousePosition
            )
            let shouldKeep = keepBySimilarity || keepByMouseMovement

            if shouldKeep {
                // Only now is the full-resolution buffer worth building.
                guard let frame = await cgWindowListCapture.materializePendingFrame() else {
                    Log.warning(
                        "[CaptureManager] Failed to materialize kept frame \(candidate.width)x\(candidate.height); dropping capture",
                        category: .capture
                    )
                    // The capture did not complete, so roll back the byte total that was
                    // added for it — otherwise averageFrameSizeBytes counts bytes for a
                    // frame that is never reflected in totalFramesCaptured.
                    totalCapturedBytes -= estimatedFrameBytes
                    return
                }
                updateCaptureMemoryLedger(currentFrameBytes: Int64(frame.imageData.count))
                lastKeptProxy = candidate.dedupProxy
                lastKeptFrameSize = FrameSize(width: candidate.width, height: candidate.height)
                lastKeptMousePosition = currentMousePosition
                let enrichedFrame = await enrichFrameMetadata(frame, trigger: trigger)
                dedupedFrameContinuation?.yield(enrichedFrame)

                stats = CaptureStatistics(
                    totalFramesCaptured: totalFrames,
                    framesDeduped: stats.framesDeduped,
                    averageFrameSizeBytes: Int(totalCapturedBytes / Int64(max(totalFrames, 1))),
                    captureStartTime: stats.captureStartTime,
                    lastFrameTime: enrichedFrame.timestamp
                )

                if trigger == .mouseClick {
                    reportMouseClickOutcome(.captured)
                }

                Log.info(
                    Self.deduplicationAnalysisLogMessage(
                        triggerDescription: triggerDescription,
                        similarity: similarity,
                        threshold: currentConfig.deduplicationThreshold,
                        keepBySimilarity: keepBySimilarity,
                        keepByMouseMovement: keepByMouseMovement,
                        outcome: "kept"
                    ),
                    category: .capture
                )
            } else {
                // The frame is discarded without ever building its full-resolution
                // buffer. This is the case that used to allocate and render
                // ~19.8 MB per frame only to throw it away.
                await cgWindowListCapture.discardPendingCapture()

                stats = CaptureStatistics(
                    totalFramesCaptured: totalFrames,
                    framesDeduped: stats.framesDeduped + 1,
                    averageFrameSizeBytes: Int(totalCapturedBytes / Int64(max(totalFrames, 1))),
                    captureStartTime: stats.captureStartTime,
                    lastFrameTime: stats.lastFrameTime
                )

                if trigger == .mouseClick {
                    reportMouseClickOutcome(.deduped)
                }

                Log.info(
                    Self.deduplicationAnalysisLogMessage(
                        triggerDescription: triggerDescription,
                        similarity: similarity,
                        threshold: currentConfig.deduplicationThreshold,
                        keepBySimilarity: keepBySimilarity,
                        keepByMouseMovement: keepByMouseMovement,
                        outcome: "deduplicated"
                    ),
                    category: .capture
                )
            }
        } else {
            // Deduplication is off, so every captured frame is kept and always needs
            // its full-resolution buffer.
            guard let frame = await cgWindowListCapture.materializePendingFrame() else {
                Log.warning(
                    "[CaptureManager] Failed to materialize frame \(candidate.width)x\(candidate.height); dropping capture",
                    category: .capture
                )
                totalCapturedBytes -= estimatedFrameBytes
                return
            }
            updateCaptureMemoryLedger(currentFrameBytes: Int64(frame.imageData.count))
            let enrichedFrame = await enrichFrameMetadata(frame, trigger: trigger)
            dedupedFrameContinuation?.yield(enrichedFrame)

            stats = CaptureStatistics(
                totalFramesCaptured: totalFrames,
                framesDeduped: 0,
                averageFrameSizeBytes: Int(totalCapturedBytes / Int64(max(totalFrames, 1))),
                captureStartTime: stats.captureStartTime,
                lastFrameTime: enrichedFrame.timestamp
            )
            lastKeptProxy = candidate.dedupProxy
            lastKeptFrameSize = FrameSize(width: candidate.width, height: candidate.height)
            lastKeptMousePosition = currentMousePosition

            if trigger == .mouseClick {
                reportMouseClickOutcome(.captured)
            }

            Log.info(
                Self.deduplicationAnalysisLogMessage(
                    triggerDescription: triggerDescription,
                    similarity: nil,
                    threshold: nil,
                    keepBySimilarity: nil,
                    keepByMouseMovement: false,
                    outcome: "kept"
                ),
                category: .capture
            )
        }
    }

    private func reportMouseClickOutcome(_ outcome: MouseClickCaptureOutcome) {
        guard let onMouseClickCaptureOutcome else { return }
        let timestamp = now()
        Task {
            await onMouseClickCaptureOutcome(outcome, timestamp)
        }
    }

    private func reportCaptureObserved(trigger: CaptureTrigger, timestamp: Date) {
        guard let onCaptureObserved else { return }
        let triggerDescription = Self.triggerLogDescription(for: trigger)
        Task {
            await onCaptureObserved(timestamp, triggerDescription)
        }
    }

    private func updateCaptureMemoryLedger(currentFrameBytes: Int64) {
        let normalizedCurrentFrameBytes = max(0, currentFrameBytes)
        // Only the reduced proxy is retained now, not the full-resolution frame.
        let lastKeptFrameBytes = Int64(lastKeptProxy?.imageData.count ?? 0)

        MemoryLedger.set(
            tag: Self.memoryLedgerCurrentFrameTag,
            bytes: normalizedCurrentFrameBytes,
            count: normalizedCurrentFrameBytes > 0 ? 1 : 0,
            unit: "frames",
            function: "capture.stream",
            kind: "current-frame"
        )
        MemoryLedger.set(
            tag: Self.memoryLedgerLastKeptFrameTag,
            bytes: lastKeptFrameBytes,
            count: lastKeptProxy == nil ? 0 : 1,
            unit: "frames",
            function: "capture.deduplication",
            kind: "reference-frame",
            note: "estimated"
        )
        MemoryLedger.emitSummary(
            reason: "capture.stream.memory",
            category: .capture,
            minIntervalSeconds: Self.memoryLedgerSummaryIntervalSeconds
        )
    }

    /// Derives the similarity keep decision from an already-computed similarity score.
    ///
    /// Semantically identical to `FrameDeduplicator.shouldKeepFrame(_:comparedTo:threshold:)`,
    /// but takes the similarity as input instead of recomputing it. The capture path
    /// already computes the score for its diagnostic log line, and the sampling scan
    /// walks ~10k pixels across two full-resolution frame buffers, so running it twice
    /// per captured frame doubled the cost of every dedup decision.
    ///
    /// `DeduplicationTests.testShouldKeepFrameForSimilarity_MatchesDeduplicator` pins
    /// the two implementations together.
    static func shouldKeepFrameForSimilarity(
        _ frame: CapturedFrame,
        comparedTo reference: CapturedFrame?,
        similarity: Double?,
        threshold: Double
    ) -> Bool {
        shouldKeepFrameForSimilarity(
            frameSize: FrameSize(width: frame.width, height: frame.height),
            referenceSize: reference.map { FrameSize(width: $0.width, height: $0.height) },
            similarity: similarity,
            threshold: threshold
        )
    }

    /// Dimension-only form, used by the capture path.
    ///
    /// The similarity score is computed from the reduced deduplication proxies, but the
    /// dimension check must run against the full-resolution sizes: a resolution change
    /// that preserves the aspect ratio produces an identically-sized proxy and would
    /// otherwise go unnoticed.
    static func shouldKeepFrameForSimilarity(
        frameSize: FrameSize,
        referenceSize: FrameSize?,
        similarity: Double?,
        threshold: Double
    ) -> Bool {
        // No reference frame: always keep, matching shouldKeepFrame.
        guard let referenceSize, let similarity else { return true }

        // A dimension change is always kept, without consulting the score.
        if frameSize != referenceSize {
            return true
        }

        // Keep when the frame changed more than the threshold allows.
        return similarity <= threshold
    }

    static func shouldKeepFrameForMouseMovement(
        enabled: Bool,
        previousMousePosition: CGPoint?,
        currentMousePosition: CGPoint?,
        minimumMovementPoints: CGFloat = 1.0
    ) -> Bool {
        guard enabled else { return false }

        switch (previousMousePosition, currentMousePosition) {
        case (nil, nil):
            return false
        case (.some, nil), (nil, .some):
            return true
        case let (.some(previous), .some(current)):
            let distance = hypot(current.x - previous.x, current.y - previous.y)
            return distance >= minimumMovementPoints
        }
    }

    static func deduplicationAnalysisLogMessage(
        triggerDescription: String,
        similarity: Double?,
        threshold: Double?,
        keepBySimilarity: Bool?,
        keepByMouseMovement: Bool,
        outcome: String
    ) -> String {
        let similarityDescription = similarity.map(Self.percentageLogDescription(for:)) ?? "n/a"
        let thresholdDescription = threshold.map(Self.percentageLogDescription(for:)) ?? "disabled"
        let keepBySimilarityDescription = keepBySimilarity.map(String.init(describing:)) ?? "n/a"

        return "Deduplication analysis (trigger: \(triggerDescription), similarity: \(similarityDescription), threshold: \(thresholdDescription), keepBySimilarity: \(keepBySimilarityDescription), keepByMouseMovement: \(keepByMouseMovement), outcome: \(outcome))"
    }

    private static func triggerLogDescription(for trigger: CaptureTrigger) -> String {
        switch trigger {
        case .mouseClick:
            return "mouse_click"
        case .windowChange:
            return "window_change"
        case .interval:
            return "interval"
        }
    }

    private static func percentageLogDescription(for value: Double) -> String {
        String(format: "%.2f%%", value * 100)
    }

    private static func mousePositionWithinCapturedFrame(_ frame: CapturedFrame) -> CGPoint? {
        mousePositionWithinCapturedFrame(
            width: frame.width,
            height: frame.height,
            displayID: frame.metadata.displayID
        )
    }

    private static func mousePositionWithinCapturedFrame(
        width frameWidth: Int,
        height frameHeight: Int,
        displayID frameDisplayID: UInt32
    ) -> CGPoint? {
        let frame = (width: frameWidth, height: frameHeight)
        guard frame.width > 0, frame.height > 0 else { return nil }
        guard let event = CGEvent(source: nil) else { return nil }

        let location = event.location
        let displayBounds = CGDisplayBounds(CGDirectDisplayID(frameDisplayID))
        guard displayBounds.width > 0,
              displayBounds.height > 0,
              displayBounds.contains(location) else {
            return nil
        }

        let relativeX = location.x - displayBounds.origin.x
        let relativeY = location.y - displayBounds.origin.y
        let scaleX = CGFloat(frame.width) / displayBounds.width
        let scaleY = CGFloat(frame.height) / displayBounds.height

        let x = relativeX * scaleX
        let y = relativeY * scaleY

        return CGPoint(
            x: min(max(x, 0), CGFloat(frame.width - 1)),
            y: min(max(y, 0), CGFloat(frame.height - 1))
        )
    }

    private func enrichFrameMetadata(
        _ frame: CapturedFrame,
        trigger: CaptureTrigger
    ) async -> CapturedFrame {
        let preferredDisplayID = frame.metadata.displayID == 0 ? nil : frame.metadata.displayID
        let shouldLookupBrowserURL: Bool = {
            guard frame.metadata.redactionReason == nil else { return false }
            guard let capturedBundleID = frame.metadata.appBundleID else { return true }
            return BrowserURLExtractor.isBrowser(capturedBundleID) || capturedBundleID == "com.apple.finder"
        }()
        let frontmostMetadata = await appInfoProvider.getFrontmostAppInfo(
            includeBrowserURL: shouldLookupBrowserURL,
            preferredDisplayID: preferredDisplayID
        )
        let redactionReason = frame.metadata.redactionReason
        let preservedDisplayID = frame.metadata.displayID != 0 ? frame.metadata.displayID : frontmostMetadata.displayID
        let captureTrigger = frame.metadata.captureTrigger ?? Self.storedCaptureTrigger(for: trigger)

        let enrichedMetadata: FrameMetadata
        if redactionReason == nil {
            enrichedMetadata = FrameMetadata(
                appBundleID: frame.metadata.appBundleID ?? frontmostMetadata.appBundleID,
                appName: frame.metadata.appName ?? frontmostMetadata.appName,
                windowName: frame.metadata.windowName ?? frontmostMetadata.windowName,
                browserURL: frame.metadata.browserURL ?? frontmostMetadata.browserURL,
                redactionReason: redactionReason,
                captureTrigger: captureTrigger,
                displayID: preservedDisplayID
            )
        } else {
            enrichedMetadata = FrameMetadata(
                appBundleID: frame.metadata.appBundleID ?? frontmostMetadata.appBundleID,
                appName: frame.metadata.appName ?? frontmostMetadata.appName,
                windowName: nil,
                browserURL: nil,
                redactionReason: redactionReason,
                captureTrigger: captureTrigger,
                displayID: preservedDisplayID
            )
        }

        return CapturedFrame(
            timestamp: frame.timestamp,
            imageData: frame.imageData,
            width: frame.width,
            height: frame.height,
            bytesPerRow: frame.bytesPerRow,
            metadata: enrichedMetadata
        )
    }

    private static func storedCaptureTrigger(for trigger: CaptureTrigger) -> FrameCaptureTrigger {
        switch trigger {
        case .mouseClick:
            return .mouse
        case .windowChange:
            return .window
        case .interval:
            return .interval
        }
    }

    private func syncCaptureDisplayIfNeeded() async {
        guard _isCapturing else { return }

        let (activeDisplayID, hasAXPermission) = await displayMonitor.getActiveDisplayIDWithPermissionStatus()
        guard hasAXPermission else { return }

        guard let captureDisplayID = currentCaptureDisplayID else {
            currentCaptureDisplayID = activeDisplayID
            return
        }

        guard activeDisplayID != captureDisplayID else { return }
        await handleDisplaySwitch(from: captureDisplayID, to: activeDisplayID)
    }

    private func scheduleDisplaySyncCheck(delayMilliseconds: UInt64 = 300) {
        deferredDisplaySyncTask?.cancel()
        deferredDisplaySyncTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(delayMilliseconds)), clock: .continuous)
            guard !Task.isCancelled else { return }
            await self?.syncCaptureDisplayIfNeeded()
        }
    }

    private static func sleepDuration(seconds: TimeInterval) -> Duration {
        let nanoseconds = max(Int64((seconds * 1_000_000_000).rounded()), 0)
        return .nanoseconds(nanoseconds)
    }

    private func shouldDropWindowChangeCapture(
        event: WindowChangeEvent,
        capturedMetadata: FrameMetadata
    ) -> Bool {
        guard let activatedApp = event.activatedApp else {
            return false
        }
        guard !activatedApp.matches(
            bundleID: capturedMetadata.appBundleID,
            appName: capturedMetadata.appName
        ) else {
            return false
        }
        return true
    }

    private func hasQueuedNewerWindowChangeEvent(overriding event: WindowChangeEvent) -> Bool {
        guard let newerEvent = latestWindowChangeEvent else { return false }
        return newerEvent.id != event.id
    }

    private func shouldSuppressWindowChangeCapture(for signature: WindowChangeSignature) -> Bool {
        guard let previousSignature = lastAcceptedWindowChangeSignature,
              let previousBundleID = previousSignature.normalizedBundleID,
              let bundleID = signature.normalizedBundleID,
              previousBundleID == bundleID,
              let previousTitle = previousSignature.normalizedTitle,
              let title = signature.normalizedTitle,
              !previousTitle.isEmpty,
              !title.isEmpty else {
            return false
        }

        return previousTitle.contains(title) || title.contains(previousTitle)
    }
}

extension CGWindowListCapture: ScreenCaptureBackend {}

extension DisplayMonitor: CaptureDisplayMonitoring {}

extension DisplaySwitchMonitor: CaptureDisplaySwitchMonitoring {
    func setOnDisplaySwitch(_ callback: (@Sendable (UInt32, UInt32) async -> Void)?) {
        onDisplaySwitch = callback
    }

    func setOnAccessibilityPermissionDenied(_ callback: (@Sendable () async -> Void)?) {
        onAccessibilityPermissionDenied = callback
    }

    func setOnWindowChange(_ callback: (@Sendable (WindowChangeEvent) async -> Void)?) {
        onWindowChange = callback
    }
}

extension AppInfoProvider: CaptureAppInfoProviding {}

extension MouseClickMonitor: CaptureMouseClickMonitoring {}

public extension Notification.Name {
    static let activeDisplayDidChange = Notification.Name("activeDisplayDidChange")
}
