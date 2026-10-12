# Screen state, suspend and networking

`ScreenStateObserver` models a snapshot as a **level** and Darwin notifications as **edges**. A re-read can establish/retain a sleep fact; it must not invent an unlock/wake. `wake()` is not proof of unlock: background activity can resume an extension while the device remains locked. `resync()` exists because notifications can be missed while suspended.

The observer is installed once per tunnel/server and cancelled synchronously at teardown. Generation/fencing and state rereads protect against stale callbacks and failed reads. `f77289f` records the essential rule: a failed notification read is `unknown`, not an unlock.

Network path state also admits a legal no-path condition (for example airplane mode). Do not add an unbounded first-path wait or interpret absence of a path as a lifecycle crash. Unit/fake coverage can miss delivery ordering and hardware notification behavior; only physical-device closure can validate those paths.
