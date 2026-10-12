# Tests and audits

| Gate | What it checks | What it does not check |
|---|---|---|
| `audit_apple_ui_boundary.py` | configured ownership, routing, selected upstream comparison/reverse dependency contracts | compilation, rendering, device behavior |
| `test_audit_apple_ui_boundary.py` | fixture/negative audit behavior | app behavior |
| `audit_hako_lossless_parity.py` | designated tokens and byte-parity source comparisons | pixel parity or touch behavior |
| `check-iphone-hako-freeze.sh` | protected freeze surface | future shipping correctness |
| `check_hako_macos_parse.py`, platform gates | static platform guards/parse assumptions | real cross-platform compile |
| screen-state / subscription SwiftPM scripts | unit seams when toolchain exists | signed Libbox/NetworkExtension integration |

Run a gate from the baseline-selected product worktree and record command, ref, exit code and environment. A report’s old count is historical evidence only.
