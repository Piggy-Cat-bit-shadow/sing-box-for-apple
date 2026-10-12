# Acceptance and evidence

Static checks establish source structure, routing, provenance tokens, or audit behavior only. They do not establish Swift compilation, signed extension behavior, pixel parity, or hardware lifecycle behavior.

The local Windows environment has no Xcode/macOS/Apple device and no `Libbox.xcframework`; therefore build, simulator, device, NetworkExtension, signing/archive/upload, and SwiftPM results are `BLOCKED_BY_ENVIRONMENT` or `NEEDS_DEVICE` unless a future run records concrete evidence.

Required before claims of release readiness: run the documented audits, build each relevant target with the correct Libbox artifact and signing on macOS, exercise iPhone/iPad/macOS separately, validate tunnel lifecycle on hardware, and perform archive/export/upload under authorized credentials. Upload success does not establish public TestFlight review approval.
