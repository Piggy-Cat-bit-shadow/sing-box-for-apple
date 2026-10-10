//
//  HakoLogView.swift
//  ApplicationLibrary
//
//  The phone's Logs page.
//
//  # Why this is thin
//
//  The fork's change to the log page is 52 added lines and 10 removed, and almost all of it is
//  presentation: the detail chrome, the canvas, an empty state and a card around the log surface. The
//  page's *content* - the command-client subscription, the level filter, the search field, the export,
//  the scroll-following rule - is upstream's and is not touched.
//
//  So this is a wrapper, not a copy. `LogViewContent` was made `public` for exactly this: a second
//  implementation of a subscription and a filter would drift from the first, and the next upstream
//  change to either would have to be made twice - which is the divergence
//  `docs/UPSTREAM-SYNC-PLAYBOOK.md` forbids.
//
//  # What it applies
//
//    * the detail navigation chrome, which is the change a user actually sees. The fork's note:
//      Logs is pushed inside Tools, so it wears the detail chrome - a circular back control, an
//      inline centred title, and no root tab bar. It previously had none of the three, which is how
//      it ended up with the platform's chevron while every page that adopted the design system had a
//      disc.
//    * the page canvas, so the log page is a page with a log on it rather than text floating on
//      whatever the platform paints behind a scroll view.
//
//  # What it deliberately does not apply
//
//  The fork also replaced the four empty-state texts with `HakoEmptyState` and wrapped the log
//  surface in a `HakoCardSurface`. Neither is reachable from outside `LogViewContent`: `emptyContent`
//  and `logScrollView` are private members of a private inner view. Reproducing them would mean
//  copying those members, and copying them is the thing this file exists to avoid. They are recorded
//  as pending in `docs/HAKO-UI-MIGRATION-MATRIX.md` rather than approximated.
//

import Library
import SwiftUI

/// The phone's Logs page: upstream's content, the fork's chrome.
public struct HakoLogView: View {
    @EnvironmentObject private var environments: ExtensionEnvironments

    public init() {}

    public var body: some View {
        LogViewContent(commandClient: environments.commandClient, initialSearchText: environments.logSearchText)
            .hakoNavigationChrome(title: String(localized: "Logs"))
            .background(HakoProductPalette.system.canvas)
    }
}
