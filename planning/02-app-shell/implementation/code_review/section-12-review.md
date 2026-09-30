# Section 12 code review (strings, root navigation, app wiring)

Overall: strings move, namespaces, maps and RootView match the plan; init order correct; maps exhaustive; iOS 15 APIs fine; no titles logged or exported.

1. HIGH - `$decisions` sink runs in willSet, so refreshAlternative reads the previous decisions (first real update sees [:]).
2. MEDIUM - launch `.active` duplicates startup, races library.start() (scan before staging cleanup), and every activation queues another full refresh.
3. MEDIUM - `.active` re-evaluates drives during a game session.
4. MEDIUM - any JITController change restarts route computation; RunLoop.main stalls in tracking mode.
5. MEDIUM - unreadable alert: recomputed on every appear (returns after "Keep"); startOver failures silent; possible iOS 15 alert/NavigationLink race (check manually).
6. MEDIUM - damaged library-secret → dead-end StartupFailureView ("restart the device"); not in the unreadable flow; failure branch drops jit.sceneBecameActive.
7. LOW - sessions path duplicated (AppServices, LiveSessionRecorder default).
8. LOW - runtime checks open drives on the main actor per game (dormant until runtimes register).
9. LOW - app.* keys outside the namespace list; unused route.reason.runtimeDeclined; previews cover one JIT reason.
