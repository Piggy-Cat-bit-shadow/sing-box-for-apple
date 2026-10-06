import Foundation
import Libbox
import Library
import SwiftUI

public extension EnvironmentValues {
    private struct showMenuBarExtraKey: EnvironmentKey {
        static let defaultValue: Binding<Bool> = .constant(true)
    }

    var showMenuBarExtra: Binding<Bool> {
        get {
            self[showMenuBarExtraKey.self]
        }
        set {
            self[showMenuBarExtraKey.self] = newValue
        }
    }

    private struct menuBarExtraSpeedModeKey: EnvironmentKey {
        static let defaultValue: Binding<Int> = .constant(1)
    }

    var menuBarExtraSpeedMode: Binding<Int> {
        get {
            self[menuBarExtraSpeedModeKey.self]
        }
        set {
            self[menuBarExtraSpeedModeKey.self] = newValue
        }
    }

    private struct selectionKey: EnvironmentKey {
        static let defaultValue: Binding<NavigationPage> = .constant(.dashboard)
    }

    var selection: Binding<NavigationPage> {
        get {
            self[selectionKey.self]
        }
        set {
            self[selectionKey.self] = newValue
        }
    }

    private struct importRemoteProfileKey: EnvironmentKey {
        static var defaultValue: Binding<LibboxImportRemoteProfile?> = .constant(nil)
    }

    var importRemoteProfile: Binding<LibboxImportRemoteProfile?> {
        get {
            self[importRemoteProfileKey.self]
        }
        set {
            self[importRemoteProfileKey.self] = newValue
        }
    }

    private struct importProfileKey: EnvironmentKey {
        static var defaultValue: Binding<LibboxProfileContent?> = .constant(nil)
    }

    var importProfile: Binding<LibboxProfileContent?> {
        get {
            self[importProfileKey.self]
        }
        set {
            self[importProfileKey.self] = newValue
        }
    }

    private struct cardConfigurationVersionKey: EnvironmentKey {
        static var defaultValue: Int = 0
    }

    var cardConfigurationVersion: Int {
        get {
            self[cardConfigurationVersionKey.self]
        }
        set {
            self[cardConfigurationVersionKey.self] = newValue
        }
    }
}

/// Whether the page's rows take the compact metric their neighbouring first-level page uses.
///
/// A second-level settings page sits inside a `Form`, and the platform gives each row a 44pt floor
/// plus ~15pt of its own inset above and below. Our own row padding and floor then stacked on top
/// of that, which is why a one-line settings row measured 74pt where the painted first-level pages
/// are 57. The pages the review named set this; every other page keeps the platform's treatment.
private struct HakoCompactRowsKey: EnvironmentKey {
    static let defaultValue = false
}

public extension EnvironmentValues {
    var hakoCompactRows: Bool {
        get { self[HakoCompactRowsKey.self] }
        set { self[HakoCompactRowsKey.self] = newValue }
    }
}
