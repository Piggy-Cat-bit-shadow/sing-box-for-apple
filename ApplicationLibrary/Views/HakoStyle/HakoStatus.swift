//
//  HakoStatus.swift
//  ApplicationLibrary
//
//  Status and value presentation. Extracted from Hako-Client (GPL-3.0),
//  `Components/HakoStatusBadge.swift` and `Components/HakoCardTitle.swift`.
//
//  The badge is how a row says "there is something here that is not its title":
//  a count, a state, a scope. It is deliberately not a button and not a control -
//  anything interactive belongs in `HakoValueRow`'s trailing slot instead.
//

import SwiftUI

/// A compact state pill: a tinted capsule with a short label.
public struct HakoStatusBadge: View {
    public enum Emphasis {
        case neutral
        case info
        case success
        case warning
        case failure

        var tint: Color {
            switch self {
            case .neutral: .secondary
            case .info: .blue
            case .success: .green
            case .warning: .orange
            case .failure: .red
            }
        }
    }

    private let text: String
    private let emphasis: Emphasis

    public init(_ text: String, emphasis: Emphasis = .neutral) {
        self.text = text
        self.emphasis = emphasis
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(emphasis.tint)
            .padding(.horizontal, HakoTheme.Spacing.compact)
            .padding(.vertical, HakoTheme.Spacing.tight)
            .background(
                Capsule(style: .continuous)
                    .fill(emphasis.tint.opacity(0.14))
            )
            .accessibilityLabel(text)
    }
}

/// A dot and a label: the smallest way to show a live state.
public struct HakoStatusDot: View {
    private let text: String
    private let color: Color

    public init(_ text: String, color: Color) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        HStack(spacing: HakoTheme.Spacing.compact - 2) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The heading above a card's contents, for the pages that need one inside the
/// card rather than as the section caption.
public struct HakoCardTitle: View {
    private let title: Text
    private let systemImage: String?
    private let tint: Color?
    private let trailing: AnyView?

    public init(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        tint: Color? = nil
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = nil
    }

    /// A title that is already localized, or is not a localization key at all.
    public init(
        verbatim title: String,
        systemImage: String? = nil,
        tint: Color? = nil
    ) {
        self.title = Text(verbatim: title)
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = nil
    }

    public init<Trailing: View>(
        _ title: LocalizedStringKey,
        systemImage: String? = nil,
        tint: Color? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.title = Text(title)
        self.systemImage = systemImage
        self.tint = tint
        self.trailing = AnyView(trailing())
    }

    public var body: some View {
        HStack(spacing: HakoTheme.Spacing.compact) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tint ?? .secondary)
            }
            title
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: HakoTheme.Spacing.compact)
            if let trailing {
                trailing
            }
        }
    }
}

/// A key/value line used inside cards: the desktop settings idiom and the status
/// cards both read better as lines than as rows.
public struct HakoCardLine: View {
    private let title: String
    private let value: String
    private let monospacedValue: Bool
    private let systemImage: String?
    private let tint: HakoAccentRole?

    public init(
        _ title: String,
        value: String,
        monospacedValue: Bool = true,
        systemImage: String? = nil,
        tint: HakoAccentRole? = nil
    ) {
        self.title = title
        self.value = value
        self.monospacedValue = monospacedValue
        self.systemImage = systemImage
        self.tint = tint
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: HakoTheme.Spacing.compact) {
            label
            Spacer(minLength: HakoTheme.Spacing.compact)
            Text(value)
                .font(HakoTheme.FontRole.value)
                .monospacedDigitIf(monospacedValue)
                .foregroundStyle(.primary)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var label: some View {
        if let systemImage {
            Label {
                Text(title)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } icon: {
                Image(systemName: systemImage)
                    .foregroundStyle(tint?.color ?? .secondary)
            }
        } else {
            Text(title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

/// A measured figure, on its own.
///
/// A latency, a rate, a byte count: monospaced so a column of them lines up, and
/// never the primary thing on a row - the row's title is. It exists so the workspace
/// rows stop each picking `.caption` or `.subheadline` for the same number.
public struct HakoMetricText: View {
    private let text: String
    private let tint: Color?

    public init(_ text: String, tint: Color? = nil) {
        self.text = text
        self.tint = tint
    }

    public var body: some View {
        Text(text)
            .font(HakoTheme.FontRole.metric)
            .foregroundStyle(tint ?? .secondary)
            .lineLimit(1)
            .accessibilityLabel(text)
    }
}

private extension View {
    @ViewBuilder
    func monospacedDigitIf(_ enabled: Bool) -> some View {
        if enabled {
            monospacedDigit()
        } else {
            self
        }
    }
}
