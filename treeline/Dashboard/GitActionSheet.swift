import SwiftUI
import AppKit

/// Modal sheet shown **only** when a git action fails.
///
/// Surfaces the action title, the command we tried to run, the error message,
/// the full captured log, and a Copy Log button. Every text element is
/// selectable so the user can grab fragments by hand too.
///
/// Successes never present this sheet — the spinner on the originating button
/// and the refreshed branch list are the success feedback.
struct GitActionSheet: View {
    @Bindable var action: BranchesState.Action
    var onClose: () -> Void
    /// Invoked when the user clicks the suggested-recovery button. `nil`
    /// when the action has no recognised recovery — the button hides.
    var onRecover: (() -> Void)?

    /// Brief "Copied" confirmation shown next to the Copy button after a
    /// click. Auto-clears on a short timer so the affordance stays compact.
    @State private var didCopyRecently = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            errorMessage
            if action.recovery != nil {
                recoverySection
            }
            Divider()
            outputView
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 440)
    }

    /// Inline recovery suggestion shown above the log when Treeline recognises
    /// the failure as something it can fix. Explains what we'll do and lets
    /// the user opt in with a single click.
    @ViewBuilder
    private var recoverySection: some View {
        if let recovery = action.recovery, let onRecover {
            VStack(alignment: .leading, spacing: 6) {
                Text("Suggested fix")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(recovery.explanation)
                    .font(.callout)
                Button(action: onRecover) {
                    Label(recovery.buttonLabel, systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.accentColor.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.accentColor.opacity(0.4))
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(.red)
                Text(action.title)
                    .font(.headline)
                    .textSelection(.enabled)
                Spacer()
            }
            Text(action.commandPreview)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var errorMessage: some View {
        if case .failed(let message) = action.phase {
            VStack(alignment: .leading, spacing: 4) {
                Text("Error")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text(message)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var outputView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Log")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    copyLog()
                } label: {
                    Label(didCopyRecently ? "Copied" : "Copy log",
                          systemImage: didCopyRecently ? "checkmark" : "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(action.output.isEmpty)
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    if action.output.isEmpty {
                        Text("(no output)")
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(Array(action.output.enumerated()), id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : line)
                                .font(.system(.body, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("Close", role: .cancel, action: onClose)
                .keyboardShortcut(.defaultAction)
        }
    }

    /// Push the full log onto the system pasteboard. Uses the action's
    /// pre-joined `combinedLog` so the format is consistent with anything
    /// else that might want to surface the same transcript.
    private func copyLog() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(action.combinedLog, forType: .string)
        didCopyRecently = true
        Task { @MainActor in
            // Short visible "Copied" window — long enough to register, short
            // enough that the button label stops feeling stuck.
            try? await Task.sleep(for: .seconds(1.5))
            didCopyRecently = false
        }
    }
}
