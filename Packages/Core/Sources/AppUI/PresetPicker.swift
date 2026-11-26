import SwiftUI

/// A segmented choice between a few named options, such as quality presets.
public struct PresetPicker<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let label: (Value) -> String

    public init(_ title: String, selection: Binding<Value>, options: [Value], label: @escaping (Value) -> String) {
        self.title = title
        self._selection = selection
        self.options = options
        self.label = label
    }

    public var body: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option in
                Text(label(option)).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(title)
        .help(title)
    }
}
