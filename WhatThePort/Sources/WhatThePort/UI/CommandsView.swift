import AppKit
import SwiftUI

/// Saved shell commands. Run starts one in the background. The server it
/// starts shows up in the server list once it listens.
struct CommandsView: View {
    @ObservedObject var runner: CommandRunner
    @ObservedObject var monitor: ServerMonitor
    let back: () -> Void
    let openServer: (Server) -> Void

    @State private var draft = ""
    @State private var name = ""
    @State private var editingID: UUID?
    @State private var showsForm = false

    private var formVisible: Bool { showsForm || runner.commands.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                PageHeader(title: L10n.text("Run"), back: back)
                Text(L10n.text("Runs in zsh. It keeps running after you close this window."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.text2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(L10n.text("Output goes to the log. A step that asks for input stops there."))
                    .font(Theme.caption)
                    .foregroundStyle(Theme.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(EdgeInsets(top: 12, leading: Theme.inset, bottom: 16, trailing: Theme.inset))
            .frame(maxWidth: .infinity, alignment: .leading)
            SectionDivider()
            if runner.commands.isEmpty {
                emptyState
            } else {
                ScrollView { rows }
                    .frame(maxHeight: 280)
            }
            if formVisible {
                SectionDivider()
                form
            } else {
                SectionDivider()
                footer
            }
        }
    }

    private var emptyState: some View {
        Text(L10n.text("Add a command, then run it from here."))
            .font(Theme.body)
            .foregroundStyle(Theme.text2)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
    }

    private var rows: some View {
        VStack(spacing: 0) {
            ForEach(runner.commands) { command in
                row(command)
            }
        }
        .padding(6)
    }

    private func row(_ command: UserCommand) -> some View {
        CommandRow(command: command, runner: runner, monitor: monitor, edit: { edit(command) }, openServer: openServer, removed: {
            if editingID == command.id { clearForm() }
        })
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 8) {
            CommandTextBox(text: $draft)
                .frame(height: 72)
                .environment(\.layoutDirection, .leftToRight)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            TextField(L10n.text("Name"), text: $name)
                .textFieldStyle(.plain)
                .font(Theme.body)
                .padding(.horizontal, 10)
                .frame(height: 30)
                .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))

            if let lastError = runner.lastError {
                Text(lastError)
                    .font(Theme.caption)
                    .foregroundStyle(Theme.amber)
            }

            HStack(spacing: 8) {
                if !runner.commands.isEmpty {
                    Button(L10n.text("Cancel")) { clearForm() }
                        .buttonStyle(PillButtonStyle())
                }
                Button(L10n.text("Save and run")) { saveAndRun() }
                    .buttonStyle(PillButtonStyle(kind: .primary))
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(12)
    }

    private var footer: some View {
        HStack {
            Button { showsForm = true } label: {
                HStack(spacing: 7) {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                    Text(L10n.text("New command"))
                }
            }
            .buttonStyle(PillButtonStyle())
            Spacer()
        }
        .padding(12)
    }

    private func edit(_ command: UserCommand) {
        editingID = command.id
        draft = command.script
        name = command.name
        showsForm = true
    }

    private func clearForm() {
        draft = ""
        name = ""
        editingID = nil
        showsForm = false
    }

    private func saveAndRun() {
        guard let command = runner.save(id: editingID, name: name, script: draft) else { return }
        Usage.record(.runCommand)
        runner.run(command)
        clearForm()
    }
}

/// A plain text box. The placeholder is drawn at the caret, so the two share one origin.
/// SwiftUI `TextEditor` adds its own inset, which puts the caret away from a SwiftUI placeholder.
private struct CommandTextBox: NSViewRepresentable {
    @Binding var text: String

    private static let font = NSFont(name: "GeistMono-Regular", size: 11) ?? .monospacedSystemFont(ofSize: 11, weight: .regular)
    private static let placeholder = "cd ~/my-repo && git pull && pnpm i && pnpm run serve"

    func makeNSView(context: Context) -> NSScrollView {
        let textView = PlaceholderTextView()
        textView.placeholder = Self.placeholder
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.importsGraphics = false
        textView.font = Self.font
        textView.textColor = Self.ink
        textView.insertionPointColor = Self.ink
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 10, height: 8)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.automaticallyAdjustsContentInsets = false
        scroll.contentInsets = NSEdgeInsets()
        scroll.focusRingType = .none
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let textView = scroll.documentView as? PlaceholderTextView else { return }
        if textView.string != text {
            textView.string = text
            textView.needsDisplay = true
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    private static let ink = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark
            ? NSColor(srgbRed: 0xF5 / 255, green: 0xF5 / 255, blue: 0xF7 / 255, alpha: 1)
            : NSColor(srgbRed: 0x1D / 255, green: 0x1D / 255, blue: 0x22 / 255, alpha: 1)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        init(text: Binding<String>) { self.text = text }

        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            text.wrappedValue = view.string
            view.needsDisplay = true
        }
    }
}

/// Draws the sample command on the same line as the caret.
private final class PlaceholderTextView: NSTextView {
    var placeholder = ""

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholder.isEmpty, let font, let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        // The caret is the extra line fragment. `draw(at:)` is a baseline, and in this
        // flipped view that baseline puts the sample on the next line.
        var rect = layoutManager.extraLineFragmentRect
        if rect.height <= 0 {
            rect.size.height = layoutManager.defaultLineHeight(for: font)
        }
        let origin = textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        let bottom = bounds.height - textContainerInset.height
        rect.size.height = max(rect.height, bottom - rect.origin.y)
        let hint = NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb: UInt32 = isDark ? 0xEBEBF5 : 0x1D1D22
            return NSColor(srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
                           green: CGFloat((rgb >> 8) & 0xFF) / 255,
                           blue: CGFloat(rgb & 0xFF) / 255,
                           alpha: isDark ? 0.4 : 0.62)
        }
        (placeholder as NSString).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [
                .font: font,
                .foregroundColor: hint,
            ]
        )
    }
}

private struct CommandRow: View {
    let command: UserCommand
    @ObservedObject var runner: CommandRunner
    @ObservedObject var monitor: ServerMonitor
    let edit: () -> Void
    let openServer: (Server) -> Void
    let removed: () -> Void
    @State private var isHovered = false

    var body: some View {
        let job = runner.job(for: command.id)
        let starting = runner.starting.contains(command.id)
        let port = job.flatMap { runner.port(for: $0, servers: monitor.servers) }
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(command.name)
                    .font(Theme.bodyMedium)
                    .foregroundStyle(Theme.text1)
                    .lineLimit(1)
                Text(command.script)
                    .font(Theme.monoCaption)
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
                    .environment(\.layoutDirection, .leftToRight)
                status(job: job, starting: starting, port: port)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture(perform: edit)

            if let job {
                IconButton(systemName: "doc.text", size: 22, help: L10n.text("Open log")) {
                    NSWorkspace.shared.open(URL(fileURLWithPath: job.logPath))
                }
            }
            if job != nil || starting {
                IconButton(systemName: "stop.fill", tint: Theme.text1.opacity(0.8), background: .clear, size: 22, help: L10n.text("Stop")) {
                    Usage.record(.stop)
                    runner.stop(command)
                }
            } else {
                IconButton(systemName: "play.fill", size: 22, help: L10n.text("Run")) {
                    Usage.record(.runCommand)
                    runner.run(command)
                }
            }
            IconButton(systemName: "xmark", size: 22, help: L10n.text("Remove")) {
                runner.remove(command)
                removed()
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .hoverHighlight(isHovered)
        .onHover { isHovered = $0 }
    }

    @ViewBuilder private func status(job: CommandJob?, starting: Bool, port: Int?) -> some View {
        if let port {
            Button(L10n.format("Listening on port %d", port)) {
                if let server = monitor.server(port: port) { openServer(server) }
            }
            .buttonStyle(.plain)
            .font(Theme.caption)
            .foregroundStyle(Theme.text2)
        } else if starting || job != nil {
            Text(L10n.text("Running"))
                .font(Theme.caption)
                .foregroundStyle(Theme.text2)
        }
    }
}
