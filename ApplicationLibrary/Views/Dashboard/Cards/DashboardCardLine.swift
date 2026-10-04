import SwiftUI

/// A key/value line inside a card.
public struct DashboardCardLine: View {
    private let label: String
    private let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }

    public var body: some View {
        HakoCardLine(label, value: value)
    }
}
