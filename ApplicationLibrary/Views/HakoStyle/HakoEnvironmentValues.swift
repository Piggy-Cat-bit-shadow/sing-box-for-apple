//
//  HakoEnvironmentValues.swift
//  ApplicationLibrary
//
//  The phone's environment keys.
//
//  # Why this file exists instead of a line in upstream's `EnvironmentValues.swift`
//
//  The original carried `hakoCompactRows` inside the shared
//  `ApplicationLibrary/Views/EnvironmentValues.swift`. That file is upstream's and an iPad and a Mac
//  compile it, so the phone's key living there means the phone's namespace is reachable from the
//  official UI's own environment file - the kind of boundary crossing this work exists to remove.
//
//  Swift does not require the declaration to be in that file. An `EnvironmentValues` member may be
//  declared from any file in the module, so the key and its extension member live here, in the fork's
//  own namespace, and upstream's file is left at its pinned bytes.
//
//  # What the key does, in the original's words
//
//  Whether the page's rows take the compact metric their neighbouring first-level page uses. A
//  second-level settings page sits inside a `Form`, and the platform gives each row a 44pt floor plus
//  about 15pt of its own inset above and below; the fork's own row padding and floor then stacked on
//  top of that, which is why a one-line settings row measured 74pt where the painted first-level pages
//  are 57. `HakoScaffold` sets it to true and `HakoRow` reads it.
//
//  # Reachability
//
//  Set by `HakoStyle/HakoScaffold.swift`, read by `HakoStyle/HakoRow.swift` - both the original's
//  bytes - and by nothing else. The default is false, so a page that does not opt in keeps the
//  platform's own row treatment, which is what upstream's dashboard, settings and profile pages get.
//

import SwiftUI

private struct HakoCompactRowsKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    /// Whether the page's rows take the compact metric their neighbouring first-level page uses.
    var hakoCompactRows: Bool {
        get {
            self[HakoCompactRowsKey.self]
        }
        set {
            self[HakoCompactRowsKey.self] = newValue
        }
    }
}
