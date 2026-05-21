import SwiftUI

/// Modal sheet that hosts a single in-flight (or just-finished) git action.
///
/// Shows the command preview, a live-updating output transcript, and a status
/// line. The sheet is dismissable via Close once the action finishes — there's
/// no auto-dismiss so the user can read the final output, especially on
/// failure. Cancelling an in-flight action isn't supported in v1: a half-done
/// `git pull` is harder to reason about than waiting for it to finish.
struct GitActionSheet: View {
    @Bindable var action: BranchesState.Action
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            outputView
            Divider()
            footer
        }
        .padding(20)
        .frame(minWidth: 560, idealWidth: 640, minHeight: 360, idealHeight: 440)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                statusIcon
                Text(action.title)
                    .font(.headline)
                Spacer()
            }
            Text(action.commandPreview)
                .font(.system(.callout, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch action.phase {
        case .running:
            ProgressView()
                .controlSize(.small)
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundStyle(.red)
        }
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(action.output.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .id(index)
                    }
                    // Sentinel row pinned to the bottom; scrolling to it keeps
                    // the latest line visible without depending on count math.
                    Color.clear.frame(height: 1).id("__tail")
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(.quaternary)
            )
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: action.output.count) { _, _ in
                withAnimation(.linear(duration: 0.05)) {
                    proxy.scrollTo("__tail", anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(alignment: .firstTextBaseline) {
            statusMessage
            Spacer()
            Button(role: action.isFinished ? .cancel : nil) {
                onClose()
            } label: {
                Text(action.isFinished ? "Close" : "Hide")
            }
            .keyboardShortcut(.defaultAction)
            .disabled(false)
        }
    }

    @ViewBuilder
    private var statusMessage: some View {
        switch action.phase {
        case .running:
            Text("Running…")
                .foregroundStyle(.secondary)
        case .succeeded:
            Text("Done")
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .foregroundStyle(.red)
                .font(.callout)
                .lineLimit(3)
                .textSelection(.enabled)
        }
    }
}
