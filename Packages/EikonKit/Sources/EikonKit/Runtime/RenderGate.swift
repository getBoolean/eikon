import CEikonSession
import Darwin
import Foundation

/// Stops GPU work when the app leaves the foreground: render threads enter before a
/// frame and leave after committing it; the host closes the gate and waits for frames in
/// flight. Not actor-isolated, since render threads call it.
public final class RenderGate: @unchecked Sendable {
    private let handle: OpaquePointer

    /// Starts open.
    public init() {
        guard let handle = eikon_render_gate_create() else { fatalError("render gate: out of memory") }
        self.handle = handle
    }

    deinit {
        eikon_render_gate_destroy(handle)
    }

    /// False when the gate is closed: skip the frame.
    public func enter() -> Bool {
        eikon_render_gate_enter(handle)
    }

    public func leave() {
        eikon_render_gate_leave(handle)
    }

    /// Closes the gate, then waits for frames in flight to leave, never past `timeout`.
    /// True when they all left.
    @discardableResult
    public func close(timeout: TimeInterval = 0.1) -> Bool {
        eikon_render_gate_set_closed(handle, true)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while eikon_render_gate_in_flight(handle) > 0 {
            if ProcessInfo.processInfo.systemUptime >= deadline { return false }
            usleep(1000)
        }
        return true
    }

    public func open() {
        eikon_render_gate_set_closed(handle, false)
    }
}
