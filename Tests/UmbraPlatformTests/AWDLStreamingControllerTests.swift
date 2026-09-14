import Foundation
@testable import UmbraPlatform
import XCTest

final class AWDLStreamingControllerTests: XCTestCase {
    func testDisableLeaseRestoresOnlyAPreviouslyEnabledInterface() async {
        let commands = ControlledAWDLCommands(state: .up)
        let controller = AWDLStreamingController(commands: commands)

        let firstBegin = await controller.begin(disableWhileStreaming: true)
        let disabledState = await commands.state
        let firstFinish = await controller.finish()
        let restoredState = await commands.state
        let firstBeginCount = await commands.beginCount
        let firstEndCount = await commands.endCount
        XCTAssertEqual(firstBegin, .disabled)
        XCTAssertEqual(disabledState, .down)
        XCTAssertEqual(firstFinish, .restored)
        XCTAssertEqual(restoredState, .up)
        XCTAssertEqual(firstBeginCount, 1)
        XCTAssertEqual(firstEndCount, 1)

        await commands.setState(.down)
        let secondBegin = await controller.begin(disableWhileStreaming: true)
        let secondFinish = await controller.finish()
        let preservedState = await commands.state
        let secondBeginCount = await commands.beginCount
        let secondEndCount = await commands.endCount
        XCTAssertEqual(secondBegin, .alreadyDisabled)
        XCTAssertEqual(secondFinish, .unchanged)
        XCTAssertEqual(preservedState, .down)
        XCTAssertEqual(secondBeginCount, 2)
        XCTAssertEqual(secondEndCount, 2)
    }

    func testFinishCancelsInFlightActivationAndRestoresBeforeReturning() async {
        let commands = ControlledAWDLCommands(state: .up, suspendBegin: true)
        let controller = AWDLStreamingController(commands: commands)
        let beginTask = Task { await controller.begin(disableWhileStreaming: true) }
        await commands.waitUntilBeginStarted()
        let disabledState = await commands.state
        XCTAssertEqual(disabledState, .down)

        let finishTask = Task { await controller.finish() }
        await commands.resumeBegin()

        guard case .failed = await beginTask.value else {
            return XCTFail("Cancelled activation must not be reported as active.")
        }
        _ = await finishTask.value
        let restoredState = await commands.state
        let endCount = await commands.endCount
        XCTAssertEqual(restoredState, .up)
        XCTAssertEqual(endCount, 1)
    }

    func testNewBeginWaitsForPreviousRestoration() async {
        let commands = ControlledAWDLCommands(state: .up, suspendEnd: true)
        let controller = AWDLStreamingController(commands: commands)
        let firstBegin = await controller.begin(disableWhileStreaming: true)
        XCTAssertEqual(firstBegin, .disabled)

        let finishTask = Task { await controller.finish() }
        await commands.waitUntilEndStarted()
        let nextBeginTask = Task { await controller.begin(disableWhileStreaming: true) }
        await Task.yield()
        let countWhileRestoring = await commands.beginCount
        XCTAssertEqual(countWhileRestoring, 1)

        await commands.resumeEnd()
        let firstFinish = await finishTask.value
        let secondBegin = await nextBeginTask.value
        let completedBeginCount = await commands.beginCount
        let secondDisabledState = await commands.state
        let secondFinish = await controller.finish()
        XCTAssertEqual(firstFinish, .restored)
        XCTAssertEqual(secondBegin, .disabled)
        XCTAssertEqual(completedBeginCount, 2)
        XCTAssertEqual(secondDisabledState, .down)
        XCTAssertEqual(secondFinish, .restored)
    }
}

private actor ControlledAWDLCommands: AWDLInterfaceCommandExecuting {
    private(set) var state: AWDLInterfaceState
    private(set) var beginCount = 0
    private(set) var endCount = 0
    private var suspendBegin: Bool
    private var suspendEnd: Bool
    private var beginStarted = false
    private var endStarted = false
    private var restoreState: AWDLInterfaceState?
    private var beginStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var endStartedWaiters: [CheckedContinuation<Void, Never>] = []
    private var beginRelease: CheckedContinuation<Void, Never>?
    private var endRelease: CheckedContinuation<Void, Never>?

    init(
        state: AWDLInterfaceState,
        suspendBegin: Bool = false,
        suspendEnd: Bool = false
    ) {
        self.state = state
        self.suspendBegin = suspendBegin
        self.suspendEnd = suspendEnd
    }

    func currentState() -> AWDLInterfaceState { state }

    func acquireDisableLease() async -> AWDLInterfaceState {
        beginCount += 1
        if restoreState == nil { restoreState = state }
        state = .down
        beginStarted = true
        beginStartedWaiters.forEach { $0.resume() }
        beginStartedWaiters.removeAll()
        if suspendBegin {
            await withCheckedContinuation { beginRelease = $0 }
            suspendBegin = false
        }
        return state
    }

    func releaseDisableLease() async -> AWDLInterfaceState {
        endCount += 1
        endStarted = true
        endStartedWaiters.forEach { $0.resume() }
        endStartedWaiters.removeAll()
        if suspendEnd {
            await withCheckedContinuation { endRelease = $0 }
            suspendEnd = false
        }
        state = restoreState ?? state
        restoreState = nil
        return state
    }

    func setState(_ state: AWDLInterfaceState) {
        self.state = state
    }

    func waitUntilBeginStarted() async {
        guard !beginStarted else { return }
        await withCheckedContinuation { beginStartedWaiters.append($0) }
    }

    func waitUntilEndStarted() async {
        guard !endStarted else { return }
        await withCheckedContinuation { endStartedWaiters.append($0) }
    }

    func resumeBegin() {
        beginRelease?.resume()
        beginRelease = nil
    }

    func resumeEnd() {
        endRelease?.resume()
        endRelease = nil
    }
}
