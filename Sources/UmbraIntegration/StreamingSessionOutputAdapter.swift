import Foundation
import UmbraMedia
import UmbraPlatform
import UmbraStreaming

public typealias StreamTransportStatistics = UmbraStreaming.StreamingStatistics

public protocol StreamingEventOutputHandling: Sendable {
    func handle(_ event: StreamingEvent)
    func handleVideoStatistics(_ statistics: MediaPipelineStatistics)
    func handleProtocolV3Statistics(_ statistics: ProtocolV3SessionStatistics)
    func beginSession() async
    func endSession() async
}

public extension StreamingEventOutputHandling {
    func handleVideoStatistics(_ statistics: MediaPipelineStatistics) {}
    func handleProtocolV3Statistics(_ statistics: ProtocolV3SessionStatistics) {}
    func beginSession() async {}
    func endSession() async {}
}

public protocol ControllerMotionPolicyProviding: Sendable {
    var controllerMotionPolicy: ControllerMotionPolicy { get }
}

public struct DiscardingStreamingEventOutputHandler: StreamingEventOutputHandling, Sendable {
    public init() {}
    public func handle(_ event: StreamingEvent) {}
}

@MainActor
public protocol ControllerMotionEnabling: AnyObject {
    func setMotionReportingEnabled(_ enabled: Bool)
}

@MainActor
public protocol ControllerFeedbackSessionControlling: AnyObject {
    func beginFeedbackSession()
    func endFeedbackSession()
}

extension AppleGameControllerService: ControllerMotionEnabling {}
extension AppleGameControllerService: ControllerFeedbackSessionControlling {}

private final class StreamingOutputSessionState: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false

    var isActive: Bool { lock.withLock { active } }
    func setActive(_ active: Bool) { lock.withLock { self.active = active } }
}

/// Routes host output requests back to native GameController devices. Bridge
/// callbacks may arrive on Moonlight worker threads, so framework interaction is
/// always transferred to the main actor.
public final class StreamingSessionOutputAdapter: StreamingEventOutputHandling, ControllerMotionPolicyProviding, @unchecked Sendable {
    public typealias HDRHandler = @MainActor @Sendable (Bool, StreamingHDRMetadata?) -> Void
    public typealias StatisticsHandler = @MainActor @Sendable (StreamingStatistics) -> Void
    public typealias VideoStatisticsHandler = @MainActor @Sendable (MediaPipelineStatistics) -> Void
    public typealias ProtocolV3StatisticsHandler = @MainActor @Sendable (ProtocolV3SessionStatistics) -> Void

    private let controllers: any ControllerOutputServicing
    private let motionEnabler: (any ControllerMotionEnabling)?
    private let feedbackSessionController: (any ControllerFeedbackSessionControlling)?
    public let controllerMotionPolicy: ControllerMotionPolicy
    private let hdrHandler: HDRHandler
    private let statisticsHandler: StatisticsHandler
    private let videoStatisticsHandler: VideoStatisticsHandler
    private let protocolV3StatisticsHandler: ProtocolV3StatisticsHandler
    private let sessionState = StreamingOutputSessionState()
    private let callbackLock = NSLock()
    private var callbackTail: Task<Void, Never>?

    public init(
        controllers: any ControllerOutputServicing,
        motionEnabler: (any ControllerMotionEnabling)? = nil,
        feedbackSessionController: (any ControllerFeedbackSessionControlling)? = nil,
        motionPolicy: ControllerMotionPolicy = ControllerMotionPolicy(),
        hdrHandler: @escaping HDRHandler = { _, _ in },
        statisticsHandler: @escaping StatisticsHandler = { _ in },
        videoStatisticsHandler: @escaping VideoStatisticsHandler = { _ in },
        protocolV3StatisticsHandler: @escaping ProtocolV3StatisticsHandler = { _ in }
    ) {
        self.controllers = controllers
        self.motionEnabler = motionEnabler
        self.feedbackSessionController = feedbackSessionController
            ?? (controllers as? any ControllerFeedbackSessionControlling)
        self.controllerMotionPolicy = motionPolicy
        self.hdrHandler = hdrHandler
        self.statisticsHandler = statisticsHandler
        self.videoStatisticsHandler = videoStatisticsHandler
        self.protocolV3StatisticsHandler = protocolV3StatisticsHandler
    }

    public func handleVideoStatistics(_ statistics: MediaPipelineStatistics) {
        enqueueCallback { [videoStatisticsHandler, sessionState] in
            guard sessionState.isActive else { return }
            videoStatisticsHandler(statistics)
        }
    }

    public func handleProtocolV3Statistics(_ statistics: ProtocolV3SessionStatistics) {
        enqueueCallback { [protocolV3StatisticsHandler, sessionState] in
            guard sessionState.isActive else { return }
            protocolV3StatisticsHandler(statistics)
        }
    }

    public func beginSession() async {
        let callback = enqueueCallback {
            [controllerMotionPolicy, feedbackSessionController, motionEnabler, sessionState] in
            controllerMotionPolicy.reset()
            motionEnabler?.setMotionReportingEnabled(false)
            feedbackSessionController?.beginFeedbackSession()
            sessionState.setActive(true)
        }
        await callback.value
    }

    public func endSession() async {
        let callback = enqueueCallback {
            [controllerMotionPolicy, feedbackSessionController, motionEnabler, sessionState] in
            sessionState.setActive(false)
            controllerMotionPolicy.reset()
            motionEnabler?.setMotionReportingEnabled(false)
            feedbackSessionController?.endFeedbackSession()
        }
        await callback.value
    }

    public func handle(_ event: StreamingEvent) {
        switch event {
        case let .rumble(controller, lowFrequency, highFrequency):
            send(.rumble(lowFrequency: lowFrequency, highFrequency: highFrequency), controller: controller)
        case let .triggerRumble(controller, left, right):
            send(.triggerRumble(left: left, right: right), controller: controller)
        case let .controllerLED(controller, red, green, blue):
            send(.led(red: red, green: green, blue: blue), controller: controller)
        case let .motionState(controller, type, reportRateHz):
            guard let player = UInt8(exactly: controller) else { return }
            enqueueCallback { [controllerMotionPolicy, motionEnabler, sessionState] in
                guard sessionState.isActive else { return }
                controllerMotionPolicy.setReportRate(reportRateHz, player: player, motionType: type)
                motionEnabler?.setMotionReportingEnabled(controllerMotionPolicy.hasEnabledMotion)
            }
        case let .adaptiveTriggers(controller, flags, leftType, rightType, left, right):
            let leftEffect = Self.adaptiveTriggerEffect(
                type: leftType,
                payload: left,
                enabled: flags & 0x08 != 0
            )
            let rightEffect = Self.adaptiveTriggerEffect(
                type: rightType,
                payload: right,
                enabled: flags & 0x04 != 0
            )
            send(.adaptiveTriggers(left: leftEffect, right: rightEffect), controller: controller)
        case let .hdrMode(enabled, metadata):
            enqueueCallback { [hdrHandler, sessionState] in
                guard sessionState.isActive else { return }
                hdrHandler(enabled, metadata)
            }
        case let .statistics(statistics):
            enqueueCallback { [statisticsHandler, sessionState] in
                guard sessionState.isActive else { return }
                statisticsHandler(statistics)
            }
        default:
            break
        }
    }

    public static func adaptiveTriggerEffect(
        type: UInt8,
        payload: Data,
        enabled: Bool
    ) -> AdaptiveTriggerEffect {
        guard enabled else { return .off }
        let bytes = Array(payload.prefix(10))
        func byte(_ index: Int) -> UInt8 { index < bytes.count ? bytes[index] : 0 }
        func position(_ value: UInt8) -> Float { min(Float(value) / 9, 1) }
        func strength(_ value: UInt8) -> Float { min(Float(value) / 8, 1) }

        switch type {
        case 0:
            return .off
        case 1:
            return .feedback(startPosition: position(byte(0)), strength: strength(byte(1)))
        case 2:
            let start = position(byte(0))
            let end = max(position(byte(1)), min(start + (1 / 9), 1))
            guard start < end else { return .off }
            return .weapon(startPosition: start, endPosition: end, strength: strength(byte(2)))
        case 3, 6:
            return .vibration(
                startPosition: position(byte(0)),
                amplitude: strength(byte(1)),
                frequency: Float(byte(2)) / Float(UInt8.max)
            )
        default:
            // Apple has no public raw-effect API. Do not approximate an unknown
            // host payload with a different physical trigger behavior.
            return .off
        }
    }

    private func send(_ command: ControllerOutputCommand, controller: UInt16) {
        guard let player = UInt8(exactly: controller) else { return }
        enqueueCallback { [controllers, sessionState] in
            guard sessionState.isActive else { return }
            _ = controllers.send(command, toPlayer: player)
        }
    }

    /// Waits until every streaming output callback submitted before this call has
    /// reached the main actor. Primarily a lifecycle/test barrier; ordering is
    /// otherwise maintained automatically by `enqueueCallback`.
    public func drainCallbacks() async {
        let tail = callbackLock.withLock { callbackTail }
        await tail?.value
    }

    @discardableResult
    private func enqueueCallback(
        _ operation: @escaping @MainActor @Sendable () -> Void
    ) -> Task<Void, Never> {
        callbackLock.withLock {
            let previous = callbackTail
            let callback = Task { @MainActor in
                await previous?.value
                operation()
            }
            callbackTail = callback
            return callback
        }
    }
}
