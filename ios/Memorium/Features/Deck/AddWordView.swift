import SwiftUI
import UIKit

/// Manual entry, built for the copy-from-Duolingo loop.
///
/// It watches the clipboard: copy a word in Duolingo, switch here, and it is
/// already offered — which is the difference between adding ten words and
/// giving up after three.
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

    @FocusState private var focus: Field?
    private enum Field { case lemma, gloss }

    var body: some View {
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

                Section("Word") {
                    TextField(
                        LanguageOption.name(for: settings.targetLang), text: $lemma
                    )
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .focused($focus, equals: .lemma)
                    .onSubmit { focus = .gloss }

                    TextField(
                        LanguageOption.name(for: settings.sourceLang), text: $gloss
                    )
                    .focused($focus, equals: .gloss)
                    .onSubmit { Task { await save() } }
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
                        .disabled(!canSave || isSaving)
                }
            }
            .onAppear(perform: checkClipboard)
        }
    }

    private var canSave: Bool {
        !lemma.trimmingCharacters(in: .whitespaces).isEmpty
            && !gloss.trimmingCharacters(in: .whitespaces).isEmpty
    }

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
        guard canSave, !isSaving else { return }
        isSaving = true
        defer { isSaving = false }

        let word = WordCreate(
            lemma: lemma.trimmingCharacters(in: .whitespaces),
            nativeGloss: gloss.trimmingCharacters(in: .whitespaces),
            notes: notes.isEmpty ? nil : notes
        )
        do {
            let created = try await settings.makeClient().addWord(word)
            addedThisSession.insert(created.lemma, at: 0)
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
