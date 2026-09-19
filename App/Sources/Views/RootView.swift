import NoteLumeCore
import SwiftUI

struct RootView: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            switch model.phase {
            case .launching:
                ProgressView("Opening your notes…").controlSize(.large)
            case .needsFolder:
                OnboardingView(model: model)
            case .failed(let message):
                ContentUnavailableView {
                    Label("Couldn't open your notes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Choose Notes Folder…") { Task { await model.chooseFolder() } }
                }
            case .ready:
                LibraryView(model: model)
            }
        }
        .onAppear { model.openLibrary = { openWindow(id: "library") } }
        .alert("Something went wrong", isPresented: Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })) {
            Button("OK") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .sheet(isPresented: Binding(get: { !model.recoveryCandidates.isEmpty }, set: { _ in })) {
            RecoverySheet(model: model)
        }
    }
}

struct OnboardingView: View {
    let model: AppModel

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "note.text").font(.system(size: 54)).foregroundStyle(.tint)
            Text("Welcome to NoteLume").font(.largeTitle.bold())
            Text("Every note is a plain Markdown file in a folder you choose, so your notes stay yours. Pick a local folder, or one inside iCloud Drive, Dropbox or any other synced location to use them on several Macs.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 460)
            Button("Choose Notes Folder…") { Task { await model.chooseFolder() } }
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            Text("No account, subscription or network connection required.")
                .font(.footnote).foregroundStyle(.tertiary)
        }
        .padding(40)
    }
}

/// Offered after a crash or forced quit: unsaved edits are never silently dropped or silently applied.
struct RecoverySheet: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Recover unsaved changes", systemImage: "arrow.counterclockwise.circle").font(.title2.bold())
            Text("NoteLume quit before these edits were saved. Restore them, or discard them (a copy stays in the note's history).")
                .foregroundStyle(.secondary)
            List(model.recoveryCandidates) { c in
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(NoteDocument(text: c.draft.text, filenameID: c.draft.noteID).displayTitle).font(.headline)
                        Text("Edited \(c.draft.savedAt.formatted(.relative(presentation: .named)))" +
                             (c.diskChangedSinceBase ? " · the file also changed afterwards" : "") +
                             (c.existsOnDisk ? "" : " · the note file is missing"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Restore") { model.restoreDraft(c) }
                    Button("Discard", role: .destructive) { model.discardDraft(c) }
                }
                .padding(.vertical, 4)
            }
            .frame(minHeight: 120, maxHeight: 260)
        }
        .padding(22)
        .frame(width: 560)
    }
}
