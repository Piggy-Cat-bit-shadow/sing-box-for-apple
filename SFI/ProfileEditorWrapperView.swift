import ApplicationLibrary
import Libbox
import SwiftUI

struct ProfileEditorWrapperView: View {
    @Binding var text: String
    let isEditable: Bool
    /// Which toolbar to put under the editor.
    ///
    /// The frozen iPhone design restyled four things in this toolbar - its background, from
    /// `.ultraThinMaterial` with a 12-point radius to the design system's card surface (twice), and its two
    /// `.bordered` buttons to `hakoSecondaryActionButtonStyle()`. That restyle lives in
    /// `HakoEditorToolbarView`.
    ///
    /// This wrapper compiles into `SFI`, and **both of that target's roots build it**: `HakoPhoneRootView`
    /// for the phone and `MainView` for an iPad. So the choice has to be a parameter rather than a change
    /// to the default - a Hako toolbar unconditionally here would put the phone's design on an iPad, and
    /// `MainView` is byte-identical to upstream precisely so that it does not.
    ///
    /// Defaulted to `false` for that reason: a caller gets the upstream toolbar unless it deliberately asks
    /// for the restyle. `MacLibrary` has its own copy of this file and is unaffected.
    var restyled: Bool = false

    @StateObject private var controller = RunestoneEditorController()
    @State private var configurationError: String?
    @State private var validationTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            RunestoneTextView(text: $text, isEditable: isEditable, controller: controller)

            if isEditable {
                if restyled {
                    HakoEditorToolbarView(
                        canUndo: controller.canUndo,
                        canRedo: controller.canRedo,
                        onUndo: { controller.undo() },
                        onRedo: { controller.redo() },
                        onFormat: { formatConfiguration() },
                        onInsertSymbol: { controller.insertSymbol($0) },
                        configurationError: configurationError,
                        onDismissError: { configurationError = nil }
                    )
                } else {
                    EditorToolbarView(
                        canUndo: controller.canUndo,
                        canRedo: controller.canRedo,
                        onUndo: { controller.undo() },
                        onRedo: { controller.redo() },
                        onFormat: { formatConfiguration() },
                        onInsertSymbol: { controller.insertSymbol($0) },
                        configurationError: configurationError,
                        onDismissError: { configurationError = nil }
                    )
                }
            }
        }
        .onChangeCompat(of: text) {
            if isEditable {
                scheduleValidation()
            }
        }
    }

    private func scheduleValidation() {
        configurationError = nil
        validationTask?.cancel()
        validationTask = Task {
            try? await Task.sleep(nanoseconds: 2 * NSEC_PER_SEC)
            guard !Task.isCancelled else { return }
            await checkConfiguration()
        }
    }

    private func checkConfiguration() async {
        let content = text
        if content.isEmpty {
            return
        }
        var error: NSError?
        LibboxCheckConfig(content, &error)
        if let error {
            configurationError = error.localizedDescription
        } else {
            configurationError = nil
        }
    }

    private func formatConfiguration() {
        let content = text
        if content.isEmpty {
            return
        }
        var error: NSError?
        let result = LibboxFormatConfig(content, &error)
        if let error {
            configurationError = error.localizedDescription
            return
        }
        if let formatted = result?.value, formatted != content {
            controller.setText(formatted)
        }
    }
}
