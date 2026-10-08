// The one symbol `Library/Database/Profile+Update.swift` takes from Libbox: the configuration
// check. The real one runs the kernel's own parser; this one only needs to be substitutable, since
// every test that cares whether validation happened injects its own validator and the tests that
// exercise the real `updateRemoteProfile` path always inject validation too.
//
// The module name must be `Libbox` because that is what the app source imports.

import Foundation

/// Reports success for any content. A test that needs a rejection injects its own validator.
public func LibboxCheckConfig(_ content: String, _ error: NSErrorPointer) {
    _ = content
    error?.pointee = nil
}
