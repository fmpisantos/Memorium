import SwiftUI
import UIKit

/// Manual entry, built for the copy-from-Duolingo loop.
///
/// It watches the clipboard: copy a word in Duolingo, switch here, and it is
/// already offered — which is the difference between adding ten words and
/// giving up after three.
///
/// Only one side has to be typed. Either field translates into the other, on
/// demand from the button beside it or automatically when you move on.
struct AddWordView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let onAdded: () -> Void

    @State private var lemma = ""
    @State private var gloss = ""
    @State private var notes = ""
    @State private var isSaving = false
    @State private var error: String?
    @State private var addedThisSession: [String] = []
    @State private var clipboardSuggestion: String?

    /// The field currently being filled by a translation, if any.
    @State private var translating: Field?
    @State private var translateTask: Task<Void, Never>?

    @FocusState private var focus: Field?
    private enum Field {
        case lemma, gloss

        var other: Field { self == .lemma ? .gloss : .lemma }
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

                if let error {
                    Section { Text(error).foregroundStyle(.red).font(.callout) }
                }

                if !addedThisSession.isEmpty {
                    Section("Added just now") {
                        ForEach(addedThisSession, id: \.self) { word in
                            Label(word, systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        }
                    }
                }
            }
            .navigationTitle("Add word")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { Task { await save() } }
                        .disabled(!canAdd || isSaving)
                }
            }
            .onChange(of: focus) { old, _ in
                // Translating as focus leaves a field, rather than on every
                // keystroke, means one request per word instead of ten.
                guard let old, settings.autoTranslate, filledSide == old else { return }
                startTranslation(from: old)
            }
            .onAppear(perform: checkClipboard)
            .onDisappear { translateTask?.cancel() }
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

    private func submitFromGloss() {
        if !canSave, settings.autoTranslate, filledSide == .gloss {
            startTranslation(from: .gloss)
        } else {
            Task { await save() }
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

    // MARK: - Actions

    private func checkClipboard() {
        focus = .lemma
        // hasStrings avoids triggering the paste notification banner unless
        // there is actually something short enough to be a word.
        guard UIPasteboard.general.hasStrings,
              let text = UIPasteboard.general.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, text.count <= 40, !text.contains("\n")
        else { return }
        clipboardSuggestion = text
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        if !canSave {
            // Adding with one side blank means "translate it, then add".
            guard settings.autoTranslate, let source = filledSide else { return }
            translateTask?.cancel()
            await fillOtherSide(from: source)
            guard canSave else { return }
        }

        let word = WordCreate(
            lemma: trimmed(.lemma),
            nativeGloss: trimmed(.gloss),
            notes: notes.isEmpty ? nil : notes
        )
        do {
            let created = try await settings.makeClient().addWord(word)
            addedThisSession.insert(created.lemma, at: 0)
            // An in-flight translation would land in the fields of the next
            // word rather than this one.
            translateTask?.cancel()
            translating = nil
            // Stay on the sheet so a run of words can be added without
            // reopening it each time.
            lemma = ""
            gloss = ""
            notes = ""
            error = nil
            focus = .lemma
            onAdded()
        } catch let APIError.server(status, detail) where status == 409 {
            error = detail.isEmpty ? "That word is already in your deck." : detail
        } catch {
            self.error = error.localizedDescription
        }
    }
}
