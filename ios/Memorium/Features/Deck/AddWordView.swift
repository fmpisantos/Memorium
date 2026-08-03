import SwiftUI
import UIKit

/// One word waiting to be added, from the moment Add is tapped until Done
/// sends the batch. Half-filled drafts are legal: the missing side is being
/// translated in the background, and the list says so.
struct WordDraft: Identifiable, Equatable {
    enum Status: Equatable {
        case ready
        case translating
        /// Translation came back empty or failed. Carries what to tell the
        /// learner, and blocks Done until they fix or remove the draft.
        case failed(String)
    }

    let id = UUID()
    var lemma: String
    var gloss: String
    var notes: String
    var status: Status = .ready

    /// Whether this draft can be sent. Both sides must be filled in, and
    /// nothing may still be in flight or broken.
    var isComplete: Bool {
        status == .ready && !lemma.isEmpty && !gloss.isEmpty
    }

    var failure: String? {
        if case let .failed(reason) = status { return reason }
        return nil
    }
}

/// Manual entry, built for the copy-from-Duolingo loop.
///
/// It watches the clipboard: copy a word in Duolingo, switch here, and it is
/// already offered — which is the difference between adding ten words and
/// giving up after three.
///
/// Only one side has to be typed. Either field translates into the other, on
/// demand from the button beside it or automatically when you move on.
///
/// Add never waits for the network: the word joins the list below straight
/// away and its translation lands underneath it a moment later, so a run of
/// words can be typed at the speed they are read. Done sends the whole batch.
///
/// Passing `editing:` reuses the same form to change a word already in the
/// deck: same fields, same translation helpers, but it saves over the existing
/// word and closes instead of collecting a list.
struct AddWordView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    /// The word being changed, or nil when adding new ones.
    let editing: Word?
    let onSaved: () -> Void

    @State private var lemma: String
    @State private var gloss: String
    @State private var notes: String
    @State private var isSaving = false
    @State private var error: String?
    @State private var clipboardSuggestion: String?

    /// Words typed but not yet sent, newest first.
    @State private var drafts: [WordDraft] = []
    @State private var editingDraft: WordDraft?
    /// Background translations, kept so deleting a draft can cancel its own.
    @State private var draftTasks: [UUID: Task<Void, Never>] = [:]

    /// The field currently being filled by a translation, if any.
    @State private var translating: Field?
    @State private var translateTask: Task<Void, Never>?

    @FocusState private var focus: Field?
    private enum Field {
        case lemma, gloss

        var other: Field { self == .lemma ? .gloss : .lemma }
    }

    init(editing: Word? = nil, onSaved: @escaping () -> Void) {
        self.editing = editing
        self.onSaved = onSaved
        // The lemma is edited on its own; `display` would drop the article back
        // into the field and save it as part of the word.
        _lemma = State(initialValue: editing?.lemma ?? "")
        _gloss = State(initialValue: editing?.nativeGloss ?? "")
        _notes = State(initialValue: editing?.notes ?? "")
    }

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                if let suggestion = clipboardSuggestion {
                    Section {
                        Button {
                            lemma = suggestion
                            clipboardSuggestion = nil
                            focus = .gloss
                        } label: {
                            HStack {
                                Image(systemName: "doc.on.clipboard")
                                VStack(alignment: .leading) {
                                    Text("Paste “\(suggestion)”").font(.callout)
                                    Text("From your clipboard").font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                        }
                    }
                }

                Section {
                    HStack {
                        TextField(
                            LanguageOption.name(for: settings.targetLang), text: $lemma
                        )
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                        .focused($focus, equals: .lemma)
                        .onSubmit { focus = .gloss }

                        translateControl(from: .lemma)
                    }

                    HStack {
                        TextField(
                            LanguageOption.name(for: settings.sourceLang), text: $gloss
                        )
                        .focused($focus, equals: .gloss)
                        .onSubmit(submitFromGloss)

                        translateControl(from: .gloss)
                    }

                    Toggle("Translate automatically", isOn: $settings.autoTranslate)
                } header: {
                    Text("Word")
                } footer: {
                    Text("Fill in either side and the other is translated for you.")
                }

                Section {
                    TextField("Notes (optional)", text: $notes, axis: .vertical)
                        .lineLimit(1 ... 3)
                } footer: {
                    Text(
                        "Article, gender, plural and example sentences are filled in automatically."
                    )
                }

                if !isEditing {
                    Section {
                        Button("Add to list", systemImage: "plus.circle.fill") { addDraft() }
                            .disabled(!canAdd)
                    }
                }

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }

                draftSection
            }
            .navigationTitle(isEditing ? "Edit word" : "Add words")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { cancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isEditing {
                        Button("Save") { Task { await saveEdit() } }
                            .disabled(!canAdd || isSaving)
                    } else {
                        Button("Done") { Task { await commit() } }
                            .disabled(!canFinish || isSaving)
                    }
                }
            }
            .sheet(item: $editingDraft) { draft in
                DraftEditorView(
                    draft: draft,
                    targetName: LanguageOption.name(for: settings.targetLang),
                    sourceName: LanguageOption.name(for: settings.sourceLang)
                ) { updated in
                    apply(updated)
                }
            }
            .onChange(of: focus) { old, _ in
                // Translating as focus leaves a field, rather than on every
                // keystroke, means one request per word instead of ten.
                guard let old, settings.autoTranslate, filledSide == old else { return }
                startTranslation(from: old)
            }
            .onAppear(perform: checkClipboard)
            .onDisappear {
                translateTask?.cancel()
                for task in draftTasks.values { task.cancel() }
            }
        }
    }

    // MARK: - The list of words waiting to be sent

    @ViewBuilder
    private var draftSection: some View {
        if !drafts.isEmpty {
            Section {
                ForEach(drafts) { draft in
                    DraftRow(draft: draft)
                        // Matches the deck: same gesture, same two buttons, so
                        // fixing a word here needs nothing new to be learnt.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                remove(draft)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                editingDraft = draft
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.accentColor)
                        }
                }
            } header: {
                Text("To add (\(drafts.count))")
            } footer: {
                if let problem = blockingProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.caption)
                } else {
                    Text("Swipe a word to edit or delete it. Done adds them all.")
                }
            }
        }
    }

    /// The translate button for `field` — or a spinner, while `field` is the
    /// one waiting to be filled in.
    @ViewBuilder
    private func translateControl(from field: Field) -> some View {
        if translating == field {
            ProgressView().controlSize(.small)
        } else if !trimmed(field).isEmpty, translating == nil {
            // Focus deliberately stays where it is: moving it would fire the
            // automatic translation too, and send the same request twice.
            Button {
                startTranslation(from: field)
            } label: {
                Image(systemName: "translate")
            }
            // Without this the whole row becomes one big button and tapping
            // anywhere in the text field fires it.
            .buttonStyle(.borderless)
            .accessibilityLabel(
                field == .lemma
                    ? "Translate into \(LanguageOption.name(for: settings.sourceLang))"
                    : "Translate into \(LanguageOption.name(for: settings.targetLang))"
            )
        }
    }

    // MARK: - State

    private var isEditing: Bool { editing != nil }

    private func value(_ field: Field) -> String {
        field == .lemma ? lemma : gloss
    }

    private func trimmed(_ field: Field) -> String {
        value(field).trimmingCharacters(in: .whitespaces)
    }

    /// The one side that has text, when the other is still blank.
    private var filledSide: Field? {
        switch (trimmed(.lemma).isEmpty, trimmed(.gloss).isEmpty) {
        case (false, true): .lemma
        case (true, false): .gloss
        default: nil
        }
    }

    private var canSave: Bool {
        !trimmed(.lemma).isEmpty && !trimmed(.gloss).isEmpty
    }

    /// Half a word is enough to tap Add when the missing half can be filled in.
    private var canAdd: Bool {
        canSave || (settings.autoTranslate && filledSide != nil)
    }

    /// Why Done is refusing, if it is. A word that could not be translated has
    /// to be corrected or dropped first -- sending it would put a half-empty
    /// word in the deck.
    private var blockingProblem: String? {
        if drafts.contains(where: { $0.failure != nil }) {
            return "Some words couldn't be translated. Swipe to fix or delete them before adding."
        }
        if drafts.contains(where: { $0.status == .translating }) {
            return "Still translating…"
        }
        if drafts.contains(where: { !$0.isComplete }) {
            return "Some words are missing a translation. Swipe to fix or delete them."
        }
        return nil
    }

    private var canFinish: Bool {
        blockingProblem == nil
    }

    private func submitFromGloss() {
        if isEditing {
            Task { await saveEdit() }
        } else if canAdd {
            addDraft()
        }
    }

    // MARK: - Translation

    private func startTranslation(from field: Field) {
        translateTask?.cancel()
        translateTask = Task { await fillOtherSide(from: field) }
    }

    /// Translates `field` into the opposite language and writes the result to
    /// the other field.
    private func fillOtherSide(from field: Field) async {
        let text = trimmed(field)
        guard !text.isEmpty, settings.isConfigured else { return }

        translating = field.other
        defer {
            // A superseded translation must not clear the spinner belonging to
            // the one that replaced it.
            if !Task.isCancelled { translating = nil }
        }

        do {
            let translation = try await settings.makeClient()
                .translate(text, into: field == .lemma ? .source : .target)
            guard !Task.isCancelled else { return }
            // The learner kept typing while this was in flight, so it now
            // translates something they no longer wrote.
            guard trimmed(field) == text else { return }

            if field == .lemma { gloss = translation } else { lemma = translation }
            error = nil
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            self.error = "Couldn't translate: \(error.localizedDescription)"
        }
    }

    /// Fills the blank side of a draft already sitting in the list. Failure is
    /// recorded on the draft rather than raised: the learner has moved on to
    /// the next word and must not be interrupted, but Done will not go through
    /// until they come back to it.
    private func translateDraft(id: UUID, into target: Field) async {
        guard settings.isConfigured else {
            markFailed(id: id, reason: "No server configured yet.")
            return
        }
        guard let draft = drafts.first(where: { $0.id == id }) else { return }
        let source = target == .gloss ? draft.lemma : draft.gloss

        do {
            let translation = try await settings.makeClient()
                .translate(source, into: target == .gloss ? .source : .target)
            guard !Task.isCancelled else { return }
            guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }

            let cleaned = translation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else {
                drafts[index].status = .failed("The translation came back empty.")
                return
            }
            if target == .gloss { drafts[index].gloss = cleaned } else { drafts[index].lemma = cleaned }
            drafts[index].status = .ready
        } catch is CancellationError {
        } catch {
            guard !Task.isCancelled else { return }
            markFailed(id: id, reason: error.localizedDescription)
        }
    }

    private func markFailed(id: UUID, reason: String) {
        guard let index = drafts.firstIndex(where: { $0.id == id }) else { return }
        drafts[index].status = .failed(reason)
    }

    // MARK: - Actions

    private func checkClipboard() {
        // Both fields already hold the word being edited, so there is nothing
        // to prompt for and nowhere useful to put the keyboard.
        guard !isEditing else { return }

        focus = .lemma
        // hasStrings avoids triggering the paste notification banner unless
        // there is actually something short enough to be a word.
        guard UIPasteboard.general.hasStrings,
              let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 40, !text.contains("\n")
        else { return }
        clipboardSuggestion = text
    }

    /// Puts what is typed into the list and empties the fields, without waiting
    /// for the network. Any missing side is translated behind the row.
    private func addDraft() {
        guard canAdd else { return }

        // The field-level translation is about to become someone else's job.
        translateTask?.cancel()
        translating = nil

        let missing = filledSide?.other
        let draft = WordDraft(
            lemma: trimmed(.lemma),
            gloss: trimmed(.gloss),
            notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
            status: missing == nil ? .ready : .translating
        )
        drafts.insert(draft, at: 0)

        lemma = ""
        gloss = ""
        notes = ""
        error = nil
        focus = .lemma

        if let missing {
            let id = draft.id
            draftTasks[id] = Task { await translateDraft(id: id, into: missing) }
        }
    }

    private func remove(_ draft: WordDraft) {
        draftTasks.removeValue(forKey: draft.id)?.cancel()
        drafts.removeAll { $0.id == draft.id }
    }

    private func apply(_ updated: WordDraft) {
        // A correction wins over whatever the translation was about to say.
        draftTasks.removeValue(forKey: updated.id)?.cancel()
        guard let index = drafts.firstIndex(where: { $0.id == updated.id }) else { return }
        drafts[index] = updated
    }

    private func cancel() {
        translateTask?.cancel()
        for task in draftTasks.values { task.cancel() }
        dismiss()
    }

    /// Sends every staged word in the order they were typed.
    private func commit() async {
        guard !isSaving else { return }

        // Anything still in the fields is a word the learner typed and never
        // tapped Add on; losing it because they reached for Done instead would
        // be the worst possible reading of the gesture.
        if canAdd { addDraft() }

        // That word may need translating first. The list now shows it with its
        // spinner, and Done comes back as soon as it lands.
        guard canFinish else { return }

        guard !drafts.isEmpty else {
            dismiss()
            return
        }

        isSaving = true
        defer { isSaving = false }

        let payload = drafts.reversed().map {
            WordCreate(
                lemma: $0.lemma,
                nativeGloss: $0.gloss,
                notes: $0.notes.isEmpty ? nil : $0.notes
            )
        }

        do {
            let result = try await settings.makeClient().addWords(payload)
            drafts.removeAll()
            onSaved()

            guard result.duplicates.isEmpty else {
                // Staying open is the only place this can be read; dismissing
                // would silently drop words the learner believes were added.
                error = "Already in your deck, so skipped: "
                    + result.duplicates.joined(separator: ", ")
                return
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Edit mode: one word, saved over the original.
    private func saveEdit() async {
        guard let editing, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        if !canSave {
            // Saving with one side blank means "translate it, then save".
            guard settings.autoTranslate, let source = filledSide else { return }
            translateTask?.cancel()
            await fillOtherSide(from: source)
            guard canSave else { return }
        }

        do {
            try await settings.makeClient().updateWord(
                id: editing.id,
                WordUpdate(
                    lemma: trimmed(.lemma),
                    nativeGloss: trimmed(.gloss),
                    notes: notes.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            )
            translateTask?.cancel()
            error = nil
            onSaved()
            dismiss()
        } catch let APIError.server(status, detail) where status == 409 {
            error = detail.isEmpty ? "That word is already in your deck." : detail
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// One staged word: both sides, always, so what is about to be added can be
/// checked at a glance rather than trusted.
private struct DraftRow: View {
    let draft: WordDraft

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(draft.lemma.isEmpty ? "—" : draft.lemma)
                    .font(.headline)
                Spacer()
                status
            }

            Text(glossLine)
                .font(.subheadline)
                .foregroundStyle(draft.gloss.isEmpty ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))

            if let failure = draft.failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.orange)
            } else if !draft.notes.isEmpty {
                Text(draft.notes)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
    }

    private var glossLine: String {
        if !draft.gloss.isEmpty { return draft.gloss }
        return draft.status == .translating ? "Translating…" : "No translation yet"
    }

    @ViewBuilder
    private var status: some View {
        switch draft.status {
        case .ready:
            EmptyView()
        case .translating:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Translating")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Translation failed")
        }
    }
}

/// Correcting a staged word before it is sent. Deliberately plain: the word,
/// its translation, and its notes, with no translation calls of its own --
/// the learner opened this because the automatic one got it wrong.
private struct DraftEditorView: View {
    @Environment(\.dismiss) private var dismiss

    let targetName: String
    let sourceName: String
    let onSave: (WordDraft) -> Void

    @State private var draft: WordDraft

    init(
        draft: WordDraft,
        targetName: String,
        sourceName: String,
        onSave: @escaping (WordDraft) -> Void
    ) {
        self.targetName = targetName
        self.sourceName = sourceName
        self.onSave = onSave
        _draft = State(initialValue: draft)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Word") {
                    TextField(targetName, text: $draft.lemma)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField(sourceName, text: $draft.gloss)
                }

                Section {
                    TextField("Notes (optional)", text: $draft.notes, axis: .vertical)
                        .lineLimit(1 ... 3)
                }

                if let failure = draft.failure {
                    Section {
                        Label(failure, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                            .font(.callout)
                    }
                }
            }
            .navigationTitle("Edit word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
        }
    }

    private var canSave: Bool {
        !draft.lemma.trimmingCharacters(in: .whitespaces).isEmpty
            && !draft.gloss.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func save() {
        var edited = draft
        edited.lemma = draft.lemma.trimmingCharacters(in: .whitespaces)
        edited.gloss = draft.gloss.trimmingCharacters(in: .whitespaces)
        edited.notes = draft.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        // Typed by hand, so whatever the translator thought no longer applies.
        edited.status = .ready
        onSave(edited)
        dismiss()
    }
}
