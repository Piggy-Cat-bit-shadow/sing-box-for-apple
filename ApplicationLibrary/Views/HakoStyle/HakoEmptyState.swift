//
//  HakoEmptyState.swift
//  ApplicationLibrary
//
//  The state a page shows when it has nothing to show.
//
//  Extracted from Hako-Client (GPL-3.0) `Sources/HakoClientUI/Components/HakoEmptyState.swift`
//  and `Components/HakoCardEmptyState.swift` at commit 62aa2f2f.
//
//  # What the reference actually draws
//
//  A bare symbol at `.largeTitle` in the secondary colour, a `.headline` title, an optional
//  `.subheadline` message, `Spacing.row` between them, and 40pt of vertical padding. There
//  is no tinted icon well and no accent colour.
//
//  That is the opposite of what this client had: a 41pt tinted rounded square with a white
//  glyph, an accent parameter, and a `Spacing.section` inset. The result was an empty state
//  that shouted louder than the content it was standing in for - a coloured badge is what a
//  row uses to say "there is something here", so using one to say "there is nothing here"
//  reads as a notification rather than as an absence.
//
//  The `accent` parameter is gone rather than ignored: a parameter that changes nothing is
//  worse than no parameter, because the next reader assumes it does something.
//

import SwiftUI

/// The state a page shows when it has nothing to show, or is waiting for something.
///
/// The symbol and the copy come from the caller, so the primitive stays a layout.
public struct HakoEmptyState: View {
    private let symbol: String
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?
    private let isBusy: Bool

    public init(
        symbol: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        isBusy: Bool = false
    ) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.isBusy = isBusy
    }

    public var body: some View {
        VStack(spacing: HakoTheme.Spacing.row) {
            if isBusy {
                ProgressView()
                    .controlSize(.large)
            } else {
                Image(systemName: symbol)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }

            Text(title)
                .font(HakoTheme.FontRole.emptyTitle)
                .multilineTextAlignment(.center)

            if let message {
                Text(message)
                    .font(HakoTheme.FontRole.emptyBody)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, HakoTheme.Spacing.section)
        .padding(.vertical, 40)
        .accessibilityElement(children: .combine)
    }
}

/// The same state, sized for a row of a settings list.
///
/// The reference separates the two because a `List` row draws its own separator and
/// background: an empty state inside one has to suppress the separator or the row reads as
/// an entry that failed to load.
public struct HakoCardEmptyState: View {
    private let symbol: String
    private let title: LocalizedStringKey
    private let message: LocalizedStringKey?

    public init(symbol: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        HakoEmptyState(symbol: symbol, title: title, message: message)
            .frame(maxWidth: .infinity)
            .listRowSeparator(.hidden)
    }
}

/// Whether a row is the selected one.
///
/// A filled mark rather than a tinted word or a bare checkmark: the state has to survive a long
/// name, a subtitle and a trailing menu without moving any of them, and it has to be readable
/// when the row is not selected. It renders both states rather than being wrapped in an `if` by
/// each caller, which is what made the pickers disagree about what "not selected" looks like.
public struct HakoSelectionMark: View {
    private let isSelected: Bool

    public init(isSelected: Bool) {
        self.isSelected = isSelected
    }

    public var body: some View {
        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
            .font(.body)
            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
            .accessibilityLabel(isSelected ? Text("Selected") : Text(""))
    }
}
