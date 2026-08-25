import XCTest
@testable import UmbraPlatform

final class ControllerSupportTests: XCTestCase {
    func testPlayerAssignmentRecomputesWhenControllerModeChanges() {
        let slots = (UInt8(0)...UInt8(3))
        XCTAssertEqual(
            slots.map { ControllerPlayerAssignment.playerIndex(slotIndex: $0, multiControllerEnabled: true) },
            [0, 1, 2, 3]
        )
        XCTAssertEqual(
            slots.map { ControllerPlayerAssignment.playerIndex(slotIndex: $0, multiControllerEnabled: false) },
            [0, 0, 0, 0]
        )
    }

    func testAxisAndTriggerMappingClampsAndHandlesNaN() {
        XCTAssertEqual(ControllerStateMapper.axis(-1), .min)
        XCTAssertEqual(ControllerStateMapper.axis(1), .max)
        XCTAssertEqual(ControllerStateMapper.axis(2), .max)
        XCTAssertEqual(ControllerStateMapper.axis(.nan), 0)
        XCTAssertEqual(ControllerStateMapper.trigger(-1), 0)
        XCTAssertEqual(ControllerStateMapper.trigger(0.5), 128)
        XCTAssertEqual(ControllerStateMapper.trigger(2), 255)
    }

    func testControllerPacketMapping() {
        let packet = ControllerStateMapper.packet(
            sample: .init(
                buttons: [.a, .dpadUp],
                leftTrigger: 0.25,
                rightTrigger: 1,
                leftStickX: -1,
                leftStickY: 1,
                rightStickX: 0,
                rightStickY: 0.5
            ),
            playerIndex: 2,
            activeControllerMask: 0b111
        )
        XCTAssertEqual(packet.playerIndex, 2)
        XCTAssertEqual(packet.activeControllerMask, 0b111)
        XCTAssertEqual(packet.buttons, [.a, .dpadUp])
        XCTAssertEqual(packet.leftTrigger, 64)
        XCTAssertEqual(packet.rightTrigger, 255)
        XCTAssertEqual(packet.leftStickX, .min)
        XCTAssertEqual(packet.leftStickY, .max)
        XCTAssertEqual(packet.rightStickY, 16_384)
    }

    @MainActor
    func testControllerReleasePacketsNeutralizeEveryActivePlayer() {
        let packets = AppleGameControllerService.neutralControllerPackets(
            playerIndices: [0, 2],
            multiControllerEnabled: true,
            activeControllerMask: 0b101
        )

        XCTAssertEqual(packets, [
            ControllerStateMapper.packet(sample: .init(), playerIndex: 0, activeControllerMask: 0b101),
            ControllerStateMapper.packet(sample: .init(), playerIndex: 2, activeControllerMask: 0b101),
        ])
        XCTAssertTrue(packets.allSatisfy {
            $0.buttons.isEmpty &&
                $0.leftTrigger == 0 && $0.rightTrigger == 0 &&
                $0.leftStickX == 0 && $0.leftStickY == 0 &&
                $0.rightStickX == 0 && $0.rightStickY == 0
        })
    }

    @MainActor
    func testSingleControllerReleaseEmitsOneNeutralMergedPlayer() {
        XCTAssertEqual(
            AppleGameControllerService.neutralControllerPackets(
                playerIndices: [0, 0, 0],
                multiControllerEnabled: false,
                activeControllerMask: 0b111
            ),
            [ControllerStateMapper.packet(sample: .init(), playerIndex: 0, activeControllerMask: 1)]
        )
    }

    @MainActor
    func testFeedbackNeutralizationContractStopsEveryPersistentDeviceOutput() {
        XCTAssertEqual(AppleGameControllerService.feedbackNeutralizationCommands, [
            .rumble(lowFrequency: 0, highFrequency: 0),
            .triggerRumble(left: 0, right: 0),
            .adaptiveTriggers(left: .off, right: .off),
            .led(red: 0, green: 0, blue: 0),
        ])
    }

    @MainActor
    func testHapticPlaybackIsBoundedToMoonlightMaximumDuration() {
        XCTAssertEqual(AppleGameControllerService.maximumHapticDuration, 30)
    }

    func testHapticTimeoutLeaseCannotCancelReplacementAndCancellationInvalidatesCurrentLease() {
        var leases = ControllerHapticLeaseRegistry()
        let original = leases.start(for: 2)
        XCTAssertTrue(leases.isCurrent(original, for: 2))

        let replacement = leases.start(for: 2)
        XCTAssertFalse(leases.isCurrent(original, for: 2))
        XCTAssertTrue(leases.isCurrent(replacement, for: 2))

        leases.cancel(for: 2)
        XCTAssertFalse(leases.isCurrent(replacement, for: 2))
    }

    @MainActor
    func testLateFeedbackIsRejectedAfterSessionTeardown() {
        let service = AppleGameControllerService()
        service.beginFeedbackSession()
        service.endFeedbackSession()

        XCTAssertEqual(
            service.send(.rumble(lowFrequency: UInt16.max, highFrequency: UInt16.max), toPlayer: 0),
            .failed("Controller feedback session is inactive.")
        )
    }

    func testSlotRegistryUsesAndReusesLowestFreeSlot() {
        var registry = ControllerSlotRegistry<String>(maximumControllerCount: 3)
        XCTAssertEqual(registry.insert("one"), 0)
        XCTAssertEqual(registry.insert("two"), 1)
        XCTAssertEqual(registry.insert("three"), 2)
        XCTAssertNil(registry.insert("four"))
        XCTAssertEqual(registry.activeMask, 0b111)
        XCTAssertEqual(registry.remove("two"), 1)
        XCTAssertEqual(registry.insert("four"), 1)
        XCTAssertEqual(registry.insert("one"), 0, "duplicate insertion is idempotent")
    }

    func testSlotRegistrySupportsAllSixteenSlotsAndHotPlugReuse() {
        var registry = ControllerSlotRegistry<Int>()
        for id in 0..<16 {
            XCTAssertEqual(registry.insert(id), UInt8(id))
        }
        XCTAssertEqual(registry.activeMask, UInt16.max)
        XCTAssertNil(registry.insert(16))

        XCTAssertEqual(registry.remove(0), 0)
        XCTAssertEqual(registry.remove(7), 7)
        XCTAssertEqual(registry.remove(15), 15)
        XCTAssertEqual(registry.activeMask, 0b0111_1111_0111_1110)

        XCTAssertEqual(registry.insert(100), 0)
        XCTAssertEqual(registry.insert(101), 7)
        XCTAssertEqual(registry.insert(102), 15)
        XCTAssertEqual(registry.activeMask, UInt16.max)
        XCTAssertEqual(registry.playerIndex(for: 101), 7)
    }

    func testControllerStateMergerUsesStrongestStickAndStableConnectionOrder() {
        let first = ControllerStateSample(
            buttons: [.a],
            leftTrigger: 0.25,
            leftStickX: 0.5,
            leftStickY: 0.5,
            rightStickX: 0.25
        )
        let second = ControllerStateSample(
            buttons: [.b],
            leftTrigger: 0.75,
            rightTrigger: 1,
            leftStickX: -0.5,
            leftStickY: -0.5,
            rightStickX: -1
        )
        let invalid = ControllerStateSample(
            leftTrigger: .nan,
            leftStickX: .nan,
            leftStickY: 1
        )

        let merged = ControllerStateMerger.merge([first, second, invalid])
        XCTAssertEqual(merged.buttons, [.a, .b])
        XCTAssertEqual(merged.leftTrigger, 0.75)
        XCTAssertEqual(merged.rightTrigger, 1)
        XCTAssertEqual(merged.leftStickX, 0.5, "first-connected controller wins equal-magnitude ties")
        XCTAssertEqual(merged.leftStickY, 0.5)
        XCTAssertEqual(merged.rightStickX, -1)
    }

    func testControllerStateMergerReplacesBothAxesWhenEitherCandidateAxisIsStronger() {
        let diagonal = ControllerStateSample(
            leftStickX: 0.7,
            leftStickY: 0.7,
            rightStickX: -0.7,
            rightStickY: -0.7
        )
        let strongerHorizontal = ControllerStateSample(
            leftStickX: 0.95,
            leftStickY: 0.1,
            rightStickX: -0.95,
            rightStickY: -0.1
        )

        let merged = ControllerStateMerger.merge([diagonal, strongerHorizontal])

        XCTAssertEqual(merged.leftStickX, 0.95)
        XCTAssertEqual(merged.leftStickY, 0.1)
        XCTAssertEqual(merged.rightStickX, -0.95)
        XCTAssertEqual(merged.rightStickY, -0.1)
    }

    func testMergedControllerMetadataUsesUnknownFamilyAndFeedbackOwnerCapabilities() throws {
        let merged = try XCTUnwrap(ControllerMetadataMerger.merge([
            ControllerMetadata(
                family: .xbox,
                supportedButtons: [.a, .b],
                capabilities: [.rumble]
            ),
            ControllerMetadata(
                family: .playStation,
                supportedButtons: [.x, .touchpad],
                capabilities: [.touchpad, .adaptiveTriggers]
            ),
        ]))

        XCTAssertEqual(merged.family, .unknown)
        XCTAssertEqual(merged.supportedButtons, [.a, .b, .x, .touchpad])
        XCTAssertEqual(
            merged.capabilities,
            [.rumble],
            "Merged feedback is owned by the deterministic lowest-slot controller."
        )
        XCTAssertNil(ControllerMetadataMerger.merge([ControllerMetadata]()))
    }

    func testMergedControllerMetadataStaysStableAcrossHeterogeneousHotPlug() {
        let first = ControllerMetadata(
            family: .xbox,
            supportedButtons: [.a],
            capabilities: [.rumble]
        )
        let heterogeneous = ControllerMetadata(
            family: .unknown,
            supportedButtons: [.a, .touchpad],
            capabilities: [.rumble]
        )

        XCTAssertEqual(
            ControllerMetadataRebindPlanner.action(from: nil, to: first),
            .arrival(first)
        )
        XCTAssertEqual(
            ControllerMetadataRebindPlanner.action(from: first, to: first),
            .stateOnly
        )
        XCTAssertEqual(
            ControllerMetadataRebindPlanner.action(from: first, to: heterogeneous),
            .stateOnly
        )
        XCTAssertEqual(
            ControllerMetadataRebindPlanner.action(from: heterogeneous, to: nil),
            .departure
        )
    }

    func testControllerNavigationMapsEdgesFocusModeAndAnalogRepeat() {
        var navigation = ControllerNavigationStateMachine()
        let pressed = ControllerStateSample(buttons: [.dpadUp, .a, .x, .start])

        XCTAssertEqual(navigation.events(for: pressed, at: 1, mode: .focusTraversal), [
            .focusPrevious,
            .activate,
            .showContextMenu,
            .showSettings,
        ])
        XCTAssertEqual(navigation.events(for: pressed, at: 1.1, mode: .focusTraversal), [])
        _ = navigation.events(for: .init(), at: 1.2, mode: .focusTraversal)
        XCTAssertEqual(
            navigation.events(for: .init(buttons: [.dpadDown, .b]), at: 1.3, mode: .directional),
            [.move(.down), .cancel]
        )

        XCTAssertEqual(
            navigation.events(for: .init(leftStickX: 1), at: 2, mode: .directional),
            [.move(.right)]
        )
        XCTAssertEqual(navigation.events(for: .init(leftStickX: 1), at: 2.1, mode: .directional), [])
        XCTAssertEqual(
            navigation.events(for: .init(leftStickX: 1), at: 2.15, mode: .directional),
            [.move(.right)]
        )
        XCTAssertEqual(navigation.events(for: .init(), at: 2.2, mode: .directional), [])
    }

    func testHeldAnalogNavigationRepeatsWithoutAnotherControllerSample() {
        var navigation = ControllerNavigationStateMachine()

        XCTAssertEqual(
            navigation.events(for: .init(leftStickY: 1), at: 10, mode: .focusTraversal),
            [.focusPrevious]
        )
        XCTAssertTrue(navigation.hasPendingAnalogRepeat)
        XCTAssertEqual(navigation.repeatedAnalogEvents(at: 10.149, mode: .focusTraversal), [])
        XCTAssertEqual(
            navigation.repeatedAnalogEvents(at: 10.15, mode: .focusTraversal),
            [.focusPrevious]
        )
        XCTAssertEqual(navigation.repeatedAnalogEvents(at: 10.299, mode: .focusTraversal), [])
        XCTAssertEqual(
            navigation.repeatedAnalogEvents(at: 10.3, mode: .focusTraversal),
            [.focusPrevious]
        )
    }

    func testAnalogReleaseStopsTimerDrivenNavigationRepeat() {
        var navigation = ControllerNavigationStateMachine()
        _ = navigation.events(for: .init(leftStickX: -1), at: 20, mode: .directional)

        XCTAssertEqual(navigation.events(for: .init(), at: 20.05, mode: .directional), [])
        XCTAssertFalse(navigation.hasPendingAnalogRepeat)
        XCTAssertEqual(navigation.repeatedAnalogEvents(at: 21, mode: .directional), [])
    }

    func testNavigationResetTearsDownPendingAnalogRepeatAndButtonEdges() {
        var navigation = ControllerNavigationStateMachine()
        _ = navigation.events(
            for: .init(buttons: [.a], leftStickX: 1),
            at: 30,
            mode: .directional
        )

        navigation.reset()

        XCTAssertFalse(navigation.hasPendingAnalogRepeat)
        XCTAssertEqual(navigation.repeatedAnalogEvents(at: 31, mode: .directional), [])
        XCTAssertEqual(
            navigation.events(for: .init(buttons: [.a]), at: 31, mode: .directional),
            [.activate]
        )
    }

    @MainActor
    func testSingleControllerFeedbackRoutesToLowestPhysicalSlot() {
        XCTAssertEqual(
            AppleGameControllerService.feedbackSlot(
                forPlayer: 0,
                assignments: [
                    (slotIndex: 5, playerIndex: 0),
                    (slotIndex: 1, playerIndex: 0),
                    (slotIndex: 3, playerIndex: 0),
                ]
            ),
            1
        )
        XCTAssertEqual(
            AppleGameControllerService.feedbackSlot(
                forPlayer: 2,
                assignments: [
                    (slotIndex: 5, playerIndex: 0),
                    (slotIndex: 2, playerIndex: 2),
                    (slotIndex: 1, playerIndex: 1),
                ]
            ),
            2
        )
        XCTAssertNil(
            AppleGameControllerService.feedbackSlot(
                forPlayer: 4,
                assignments: [(slotIndex: 0, playerIndex: 0)]
            )
        )
    }

    func testMouseModeToggleIsReleaseGatedAtSevenHundredFiftyMilliseconds() {
        var tooShort = ControllerInteractionStateMachine()
        XCTAssertEqual(
            tooShort.update(.init(buttons: [.start]), at: 1, gamepadMouseEnabled: true),
            [.hostState(.init(buttons: [.start]))]
        )
        XCTAssertFalse(tooShort.mouseModeActive)
        XCTAssertEqual(
            tooShort.update(.init(), at: 1.749, gamepadMouseEnabled: true),
            [.hostState(.init())]
        )
        XCTAssertFalse(tooShort.mouseModeActive)

        var threshold = ControllerInteractionStateMachine()
        _ = threshold.update(.init(buttons: [.start]), at: 2, gamepadMouseEnabled: true)
        XCTAssertFalse(threshold.mouseModeActive, "holding Start must not toggle before release")
        XCTAssertEqual(
            threshold.update(.init(), at: 2.750, gamepadMouseEnabled: true),
            [.hostState(.init()), .localAction(.mouseModeChanged(true))]
        )
        XCTAssertTrue(threshold.mouseModeActive)
    }

    func testShortStartPressReachesHostAndPreferenceOnlyDisablesActivation() {
        var machine = ControllerInteractionStateMachine()
        XCTAssertEqual(
            machine.update(.init(buttons: [.start]), at: 0, gamepadMouseEnabled: false),
            [.hostState(.init(buttons: [.start]))]
        )
        XCTAssertEqual(
            machine.update(.init(), at: 1, gamepadMouseEnabled: false),
            [.hostState(.init())]
        )
        XCTAssertFalse(machine.mouseModeActive)

        _ = machine.update(.init(buttons: [.start]), at: 2, gamepadMouseEnabled: true)
        _ = machine.update(.init(), at: 2.75, gamepadMouseEnabled: true)
        XCTAssertTrue(machine.mouseModeActive)
        _ = machine.update(.init(buttons: [.start]), at: 3, gamepadMouseEnabled: false)
        XCTAssertEqual(
            machine.update(.init(), at: 3.75, gamepadMouseEnabled: false),
            [.hostState(.init()), .localAction(.mouseModeChanged(false))]
        )
        XCTAssertFalse(machine.mouseModeActive)
    }

    func testMouseMovementUsesStrongerManhattanStickRightTieAndCubicCurve() {
        var machine = ControllerInteractionStateMachine()
        activateMouseMode(&machine)

        _ = machine.update(
            .init(leftStickX: 0.75, rightStickY: 0.5),
            at: 1,
            gamepadMouseEnabled: true
        )
        XCTAssertEqual(machine.mouseMovement(), .relative(deltaX: 25, deltaY: 0))

        _ = machine.update(
            .init(leftStickX: 0.5, rightStickY: 0.5),
            at: 1.1,
            gamepadMouseEnabled: true
        )
        XCTAssertEqual(
            machine.mouseMovement(),
            .relative(deltaX: 0, deltaY: -10),
            "right stick must win equal Manhattan-strength ties"
        )
        XCTAssertEqual(ControllerInteractionStateMachine.mouseDelta(8_192), 0)
        XCTAssertEqual(ControllerInteractionStateMachine.mouseDelta(16_384), 6)
        XCTAssertEqual(ControllerInteractionStateMachine.mouseDelta(-16_384), -10)
        XCTAssertEqual(ControllerInteractionStateMachine.mouseDelta(32_767), 62)
        XCTAssertEqual(ControllerInteractionStateMachine.mouseDelta(-32_768), -66)
    }

    func testMouseModeMapsFiveBalancedButtonsAndDPadScrollEdges() {
        var machine = ControllerInteractionStateMachine()
        activateMouseMode(&machine)
        let mouseButtons: ControllerButtonMask = [
            .a, .b, .x, .leftShoulder, .rightShoulder,
        ]
        let mappedMouseButtons: [MouseButton] = [.left, .right, .middle, .back, .forward]
        XCTAssertEqual(
            machine.update(.init(buttons: mouseButtons), at: 1, gamepadMouseEnabled: true),
            mappedMouseButtons.map {
                .mouseButton(.init(button: $0, action: .down))
            }
        )
        XCTAssertEqual(
            machine.update(.init(), at: 1.1, gamepadMouseEnabled: true),
            mappedMouseButtons.map {
                .mouseButton(.init(button: $0, action: .up))
            }
        )
        XCTAssertTrue(machine.mouseButtonsDown.isEmpty)

        XCTAssertEqual(
            machine.update(
                .init(buttons: [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]),
                at: 2,
                gamepadMouseEnabled: true
            ),
            [
                .scroll(.init(axis: .vertical, delta: 120)),
                .scroll(.init(axis: .vertical, delta: -120)),
                .scroll(.init(axis: .horizontal, delta: 120)),
                .scroll(.init(axis: .horizontal, delta: -120)),
            ]
        )
        XCTAssertEqual(
            machine.update(
                .init(buttons: [.dpadUp, .dpadDown, .dpadLeft, .dpadRight]),
                at: 2.1,
                gamepadMouseEnabled: true
            ),
            [],
            "scrolling is one detent per button-down edge"
        )
    }

    func testLocalChordsRequireExactMasksFireOnceAndSuppressPartialRelease() {
        let disconnect: ControllerButtonMask = [.start, .back, .leftShoulder, .rightShoulder]
        let statistics: ControllerButtonMask = [.back, .leftShoulder, .rightShoulder, .x]
        var machine = ControllerInteractionStateMachine()

        XCTAssertEqual(
            machine.update(.init(buttons: disconnect), at: 1, gamepadMouseEnabled: true),
            [.hostState(.init()), .localAction(.disconnect)]
        )
        XCTAssertEqual(machine.update(.init(buttons: disconnect), at: 1.1, gamepadMouseEnabled: true), [])
        XCTAssertEqual(
            machine.update(
                .init(buttons: [.back, .leftShoulder]),
                at: 1.2,
                gamepadMouseEnabled: true
            ),
            [],
            "partial chord release must not leak held members to the host"
        )
        XCTAssertEqual(machine.update(.init(), at: 1.3, gamepadMouseEnabled: true), [])

        XCTAssertEqual(
            machine.update(.init(buttons: statistics), at: 2, gamepadMouseEnabled: true),
            [.hostState(.init()), .localAction(.toggleStatistics)]
        )
        XCTAssertEqual(machine.update(.init(buttons: statistics), at: 2.1, gamepadMouseEnabled: true), [])
        _ = machine.update(.init(), at: 2.2, gamepadMouseEnabled: true)

        XCTAssertEqual(
            machine.update(.init(buttons: [disconnect, .a]), at: 3, gamepadMouseEnabled: true),
            [.hostState(.init(buttons: [disconnect, .a]))],
            "an extra button must prevent chord recognition"
        )
    }

    func testControllersCannotCollectivelyFormChordAndMouseModesRemainIndependent() {
        var first = ControllerInteractionStateMachine()
        var second = ControllerInteractionStateMachine()
        XCTAssertFalse(first.update(
            .init(buttons: [.start, .back]),
            at: 0,
            gamepadMouseEnabled: true
        ).contains(.localAction(.disconnect)))
        XCTAssertFalse(second.update(
            .init(buttons: [.leftShoulder, .rightShoulder]),
            at: 0,
            gamepadMouseEnabled: true
        ).contains(.localAction(.disconnect)))

        _ = first.update(.init(), at: 0.1, gamepadMouseEnabled: true)
        _ = second.update(.init(), at: 0.1, gamepadMouseEnabled: true)
        activateMouseMode(&first, startTime: 1)
        XCTAssertTrue(first.mouseModeActive)
        XCTAssertFalse(second.mouseModeActive)

        _ = first.update(.init(buttons: [.a]), at: 2, gamepadMouseEnabled: true)
        _ = second.update(.init(buttons: [.b]), at: 2, gamepadMouseEnabled: true)
        XCTAssertEqual(
            ControllerStateMerger.merge([first.hostSample, second.hostSample]).buttons,
            [.b],
            "mouse-active raw buttons must not leak through single-controller merging"
        )
    }

    func testResetBalancesMouseButtonsAndClearsTemporalAndHostState() {
        var machine = ControllerInteractionStateMachine()
        activateMouseMode(&machine)
        _ = machine.update(
            .init(buttons: [.a, .rightShoulder], leftStickX: 1),
            at: 1,
            gamepadMouseEnabled: true
        )

        XCTAssertEqual(machine.reset(), [
            .mouseButton(.init(button: .left, action: .up)),
            .mouseButton(.init(button: .forward, action: .up)),
            .localAction(.mouseModeChanged(false)),
        ])
        XCTAssertFalse(machine.mouseModeActive)
        XCTAssertTrue(machine.mouseButtonsDown.isEmpty)
        XCTAssertEqual(machine.rawSample, .init())
        XCTAssertEqual(machine.hostSample, .init())
        XCTAssertNil(machine.mouseMovement())
    }

    func testControllerTouchLifecycleRepairsOrphanMoveAndEndsContactsOnHotPlugRemoval() {
        var lifecycle = ControllerTouchLifecycle()
        let firstID = ControllerTouchContactID(touchpadIndex: 0, fingerIndex: 1)
        let secondID = ControllerTouchContactID(touchpadIndex: 0, fingerIndex: 0)
        let orphanMove = ControllerTouchContactEvent(
            id: firstID,
            phase: .moved,
            x: -0.5,
            y: 0.5,
            pressure: 0
        )

        XCTAssertEqual(lifecycle.handle(orphanMove).map(\.phase), [.began])
        XCTAssertEqual(lifecycle.handle(.init(
            id: firstID,
            phase: .moved,
            x: 0,
            y: 0,
            pressure: 0
        )).map(\.phase), [.moved])
        XCTAssertEqual(lifecycle.handle(.init(
            id: secondID,
            phase: .began,
            x: 1,
            y: -1,
            pressure: 0
        )).map(\.phase), [.began])
        XCTAssertEqual(lifecycle.handle(.init(
            id: secondID,
            phase: .began,
            x: 0.75,
            y: -0.75,
            pressure: 0
        )).map(\.phase), [.ended, .began], "duplicate down restarts a valid contact lifecycle")

        let ended = lifecycle.endAllContacts()
        XCTAssertEqual(ended.map(\.id), [secondID, firstID])
        XCTAssertEqual(ended.map(\.phase), [.ended, .ended])
        XCTAssertTrue(ended.allSatisfy { $0.pressure == 0 })
        XCTAssertEqual(lifecycle.activeContactIDs, [])
        XCTAssertEqual(lifecycle.handle(.init(
            id: firstID,
            phase: .ended,
            x: 0,
            y: 0,
            pressure: 0
        )), [])
    }

    private func activateMouseMode(
        _ machine: inout ControllerInteractionStateMachine,
        startTime: TimeInterval = 0
    ) {
        _ = machine.update(.init(buttons: [.start]), at: startTime, gamepadMouseEnabled: true)
        _ = machine.update(
            .init(),
            at: startTime + ControllerInteractionStateMachine.mouseModeLongPressDuration,
            gamepadMouseEnabled: true
        )
        XCTAssertTrue(machine.mouseModeActive)
    }

    func testControllerTouchMapperNormalizesAxesAndPressure() {
        let packet = ControllerTouchMapper.packet(
            playerIndex: 3,
            event: .init(
                id: .init(touchpadIndex: 1, fingerIndex: 2),
                phase: .moved,
                x: -0.5,
                y: 0.5,
                pressure: 2
            )
        )
        XCTAssertEqual(packet.playerIndex, 3)
        XCTAssertEqual(packet.touchpadIndex, 1)
        XCTAssertEqual(packet.fingerIndex, 2)
        XCTAssertEqual(packet.x, 0.25)
        XCTAssertEqual(packet.y, 0.25)
        XCTAssertEqual(packet.pressure, 1)
    }

    func testMotionGateHonorsRateAndDeduplicates() {
        var gate = MotionReportGate(reportRateHz: 100)
        XCTAssertTrue(gate.shouldReport(value: .init(1, 2, 3), at: 1))
        XCTAssertFalse(gate.shouldReport(value: .init(1, 2, 4), at: 1.005))
        XCTAssertTrue(gate.shouldReport(value: .init(1, 2, 4), at: 1.011))
        XCTAssertFalse(gate.shouldReport(value: .init(1, 2, 4), at: 2))
    }

    func testAdaptiveTriggerValidation() {
        XCTAssertTrue(AdaptiveTriggerEffect.off.isValid)
        XCTAssertTrue(AdaptiveTriggerEffect.feedback(startPosition: 0.2, strength: 1).isValid)
        XCTAssertFalse(AdaptiveTriggerEffect.weapon(startPosition: 0.8, endPosition: 0.4, strength: 1).isValid)
        XCTAssertFalse(AdaptiveTriggerEffect.vibration(startPosition: 0, amplitude: 2, frequency: 1).isValid)
    }
}
