# Section 10 code review (runtime protocol, render gate, session host)

Overall follows the plan: event table, arm-then-open order, bounded gate wait, codes-only logs, idempotent pause/resume.

1. HIGH - Presenter starts the session while the animated presentation is running; a fast failure's dismiss is dropped, leaving a black host. Fix: await presentation completion before start.
2. HIGH - host → session → runtime → (host) retain cycle; `end` never clears `runtime`. Fix: nil it after stop; document weak host.
3. HIGH - Overlapping ends: a second `end` returns before teardown completes; presenter clears `active`, a new session arms, then the old one's disarm closes the new ring and deletes its sentinel. Also `stop()` can overlap `launch()`. Fix: shared end task; await in-flight launch before stop.
4. MEDIUM - `runtimeDidEnd` changes no state synchronously; pause/resume still reach an ended runtime; launch-failure path may call stop() on it. Fix: mark the session synchronously.
5. MEDIUM - didEnterBackground doesn't re-drain the gate after a willDeactivate timeout before writing `.background`.
6. MEDIUM - `LiveSceneEvents(scene: nil)` observes every scene, defeating the per-scene filter. Fix: require the scene.
7. MEDIUM - Presenter records `noteLaunched` and probes the drive before the active-session check. Fix: check first; record after start.
8. LOW-MEDIUM - Double drive open: root from the first resolution, access on the second. Fix: open once.
9. LOW - No re-entry guard on `GameSession.start`.
10. LOW - Quit drops the gate-timeout breadcrumb; a racing runtimeDidEnd error is lost.
11. LOW - Memory timer runs while paused and in default run-loop mode only.
12. LOW - Registry cache never evicted; `checks` runs routes sequentially.
Notes: document nonisolated route/check for @MainActor runtimes; consider arming without the ring rather than failing launch.
