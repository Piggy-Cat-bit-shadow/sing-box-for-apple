import Foundation
import SwiftUI

public func FormView(@ViewBuilder content: () -> some View) -> some View {
    Form {
        content()
    }
    #if os(macOS)
    .formStyle(.grouped)
    #endif
}

public func FormTextItem(_ name: LocalizedStringKey, _ value: String) -> some View {
    HakoValueLine(name, value: value)
}

public func FormTextItem(_ name: LocalizedStringKey, _ systemImage: String, @ViewBuilder _ value: () -> some View) -> some View {
    HakoValueLine(name, systemImage: systemImage, value: value)
}

/// A key/value line in the shared design language.
///
/// Every detail page in the client is a stack of these, so it is the one place that decides
/// what a detail row looks like: the label secondary, the value primary and monospaced, both at
/// the same size so the eye can run down either column. It replaced a caption-sized monospaced
/// value under a plain label, which made the value the quietest thing on a page whose whole
/// content is the value.
///
/// The tvOS variant keeps its Button wrapper: the focus engine needs a focusable element, and
/// removing it would break navigation on that platform rather than restyle it.
public struct HakoValueLine<Value: View>: View {
    private let name: LocalizedStringKey
    private let systemImage: String?
    private let value: Value

    public init(_ name: LocalizedStringKey, value: String) where Value == Text {
        self.name = name
        self.systemImage = nil
        self.value = Text(value)
    }

    public init(_ name: LocalizedStringKey, systemImage: String, @ViewBuilder value: () -> Value) {
        self.name = name
        self.systemImage = systemImage
        self.value = value()
    }

    @ViewBuilder
    public var body: some View {
        #if os(tvOS)
            Button {} label: { line }
        #else
            line
        #endif
    }

    private var line: some View {
        HStack(alignment: .firstTextBaseline, spacing: HakoTheme.Spacing.compact) {
            label
            value
                .multilineTextAlignment(.trailing)
                .font(.subheadline.monospacedDigit())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var label: some View {
        let text = Text(name)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        if let systemImage {
            Label {
                text
            } icon: {
                Image(systemName: systemImage)
            }
        } else {
            text
        }
    }
}

public func FormItem(_ title: String, @ViewBuilder content: () -> some View) -> some View {
    #if os(iOS)
        HStack {
            Text(title)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            Spacer()
            content()
        }
    #elseif os(tvOS)
        HStack {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .layoutPriority(1)
            Spacer()
            Spacer()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .layoutPriority(1)
        }
    #elseif os(macOS)
        LabeledContent(title) {
            content()
                .labelsHidden()
        }
    #endif
}

public func FormToggle(_ titleKey: LocalizedStringKey, _ subtitleKey: LocalizedStringKey, _ isOn: Binding<Bool>, header: LocalizedStringKey? = nil, _ action: @escaping (_ newValue: Bool) async -> Void) -> some View {
    #if os(macOS)
        Section {
            Toggle(isOn: isOn) {
                VStack(alignment: .leading) {
                    Text(titleKey)
                    Spacer()
                    Text(subtitleKey)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .onChangeCompat(of: isOn.wrappedValue) { newValue in
                Task {
                    await action(newValue)
                }
            }
        } header: {
            if let header {
                Text(header)
            }
        }
    #else
        Section {
            Toggle(titleKey, isOn: isOn)
                .onChangeCompat(of: isOn.wrappedValue) { newValue in
                    Task {
                        await action(newValue)
                    }
                }
        } header: {
            if let header {
                Text(header)
            }
        } footer: {
            Text(subtitleKey)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    #endif
}

public func FormButton(action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
    Button(action: action, label: label)
    #if os(macOS)
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    #endif
}

public func FormButton(_ titleKey: some StringProtocol, action: @escaping () -> Void) -> some View {
    Button(titleKey, action: action)
    #if os(macOS)
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    #endif
}

public func FormButton(role: ButtonRole?, action: @escaping () -> Void, @ViewBuilder label: () -> some View) -> some View {
    Button(role: role, action: action, label: label)
    #if os(macOS)
        .buttonStyle(.plain)
        .foregroundColor(.accentColor)
    #endif
}

public func FormNavigationLink(@ViewBuilder destination: () -> some View, @ViewBuilder label: () -> some View) -> some View {
    #if !os(tvOS)
        return NavigationLink(destination: destination, label: label)
    #else
        return NavigationLink(destination: {
            destination()
                .toolbar {
                    ToolbarItemGroup(placement: .topBarLeading) {
                        BackButton()
                    }
                }
        }, label: label)
    #endif
}

public struct FormPickerOption<Value: Hashable>: Identifiable {
    public let value: Value
    public let name: String

    public var id: Value {
        value
    }

    public init(_ value: Value, _ name: String) {
        self.value = value
        self.name = name
    }
}

public struct FormPicker<Value: Hashable>: View {
    private let title: String
    private let options: [FormPickerOption<Value>]
    @Binding private var selection: Value

    public init(_ title: String, options: [FormPickerOption<Value>], selection: Binding<Value>) {
        self.title = title
        self.options = options
        _selection = selection
    }

    public var body: some View {
        #if os(tvOS)
            FormNavigationLink {
                FormPickerListView(title: title, options: options, selection: $selection)
            } label: {
                HStack {
                    Text(title)
                    Spacer()
                    Text(options.first { $0.value == selection }?.name ?? "")
                        .foregroundStyle(.secondary)
                }
            }
        #else
            Picker(title, selection: $selection) {
                ForEach(options) { option in
                    Text(option.name).tag(option.value)
                }
            }
        #endif
    }
}

#if os(tvOS)
    private struct FormPickerListView<Value: Hashable>: View {
        let title: String
        let options: [FormPickerOption<Value>]
        @Binding var selection: Value
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            FormView {
                ForEach(options) { option in
                    Button {
                        selection = option.value
                        dismiss()
                    } label: {
                        HStack {
                            Text(option.name)
                            Spacer()
                            Image(systemName: "checkmark")
                                .opacity(selection == option.value ? 1 : 0)
                        }
                    }
                }
            }
            .navigationTitle(title)
        }
    }
#endif

#if os(macOS)
    public func FormNavigationLink(value: some Hashable, @ViewBuilder label: () -> some View) -> some View {
        NavigationLink(value: value, label: label)
    }

    public extension View {
        func formNavigationDestination<D: Hashable>(for data: D.Type, @ViewBuilder destination: @escaping (D) -> some View) -> some View {
            navigationDestination(for: data, destination: destination)
        }
    }
#endif
