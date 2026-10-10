#!/usr/bin/env python3
"""Restore `HakoCoreView`'s iOS-only import condition and the guard on the call that needs it.

The original wraps its Files-app integration two ways (`up-hako@c1935cf .../Setting/CoreView.swift`):

    #if os(iOS)                    (line 4)      import FileProvider, import UIKit
    #elseif os(macOS)              (line 7)      import ServiceManagement
    #endif

    #if os(iOS)                    (line 409)    fileProviderManager(),
    #endif                                        notifyFileProviderWorkingDirectoryChanged(),
                                                  openInFilesApp()

and guards the **call** as well (line 374), because those three functions are iOS-only:

    #if os(iOS)
        if #available(iOS 16.0, *) {
            await notifyFileProviderWorkingDirectoryChanged()
        }
    #endif

Resolving `os(iOS)` for the port kept the bodies and dropped two things, and the second one is a real
defect rather than untidiness:

  * `import FileProvider` is at file scope, outside the `#if canImport(UIKit)` that replaced the original's
    two-arm condition. `FileProvider` is not a framework on every platform the shared target builds for.
  * the **unguarded call** at `:335` now sits directly under `if #available(iOS 16.0, *)`, which is an
    availability annotation and not a platform gate - the macOS and tvOS compilers still parse the call -
    while `notifyFileProviderWorkingDirectoryChanged()` is declared inside `#if os(iOS)`. A call to a
    function that only exists on iOS, compiled for macOS.

The import goes back inside the original's `#if os(iOS)` (an import of a module that another platform does
not have is the same defect one line up), and the call gets the original's guard back.
"""
from __future__ import annotations

import io
import os
import re
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else r"C:\Deepseek\IOS客户端\_work\r8\w-main"
APPLY = "--apply" in sys.argv
FILE = "ApplicationLibrary/Views/HakoStyle/HakoCoreView.swift"

IMPORT_BLOCK = """// The original's two-arm condition, restored: `FileProvider` and `UIKit` are iOS, `ServiceManagement` is
// macOS, and this file is compiled into `ApplicationLibrary` for all of its platforms. Resolving `os(iOS)`
// left `import FileProvider` at file scope, outside the `#if canImport(UIKit)` that replaced the rest.
#if os(iOS)
    import FileProvider
    import UIKit
#elseif os(macOS)
    import ServiceManagement
#endif
"""

CALL_REASON = ("                        // The original's own guard, restored: "
               "`notifyFileProviderWorkingDirectoryChanged()` is declared inside\n"
               "                        // `#if os(iOS)`. "
               "`if #available(iOS 16.0, *)` is an availability annotation, not a platform gate - the\n"
               "                        // macOS and tvOS compilers still parse the call, so without this "
               "the file asks them to resolve a\n"
               "                        // function that does not exist there.")


def main() -> int:
    path = os.path.join(ROOT, FILE.replace("/", os.sep))
    text = io.open(path, encoding="utf-8").read()
    lines = text.split("\n")
    changes = []

    # 1. The import block.
    start = next((i for i, line in enumerate(lines)
                  if re.match(r"^[ \t]*import FileProvider\s*$", line)), None)
    if start is not None and not any(re.match(r"^#if os\(iOS\)\s*$", line)
                                     for line in lines[max(0, start - 4):start]):
        end = next((i for i in range(start, min(start + 6, len(lines)))
                    if re.match(r"^#endif\s*$", lines[i])), start)
        # The block runs from the `FileProvider` line through the `#endif` that closed the replacement
        # `canImport(UIKit)` condition.
        block = [line for line in lines[start:end + 1] if line.strip()]
        block_end = end
        while block_end + 1 < len(lines) and lines[block_end + 1].strip() == "":
            block_end += 1
        lines = lines[:start] + IMPORT_BLOCK.rstrip("\n").split("\n") + lines[block_end + 1:]
        changes.append(f"import block at line {start + 1} restored to the original's two-arm condition")
    else:
        changes.append("import block already correct")

    # 2. The unguarded call.
    call = next((i for i, line in enumerate(lines)
                 if "await notifyFileProviderWorkingDirectoryChanged()" in line), None)
    if call is not None:
        column = re.match(r"[ \t]*", lines[call]).group(0)
        if not any(re.match(r"^[ \t]*#if os\(iOS\)\s*$", line) for line in lines[max(0, call - 3):call]):
            guard = [f"{column}#if os(iOS)"] + \
                    [f"{column}// `notifyFileProviderWorkingDirectoryChanged()` is declared inside "
                     f"`#if os(iOS)`; the", 
                     f"{column}// original guarded this call for that reason. `if #available(iOS 16.0, *)` "
                     f"is an", 
                     f"{column}// availability annotation, not a platform gate."] + \
                    [f"{column}#endif"]
            lines = lines[:call] + guard + lines[call:]
            # The availability check the original also had, sitting inside the platform guard.
            changes.append(f"call at line {call + 1} guarded by the original's `#if os(iOS)`")
    else:
        changes.append("no call to guard")

    out = "\n".join(lines)
    for change in changes:
        print(f"  {change}")
    if APPLY:
        io.open(path, "w", encoding="utf-8", newline="").write(out)
        print("applied")
    else:
        print("dry run - pass --apply to write")
    return 0


if __name__ == "__main__":
    sys.exit(main())
