import PhotosUI
import SwiftUI

/// Screenshot import, with a mandatory review step.
///
/// OCR misreads diacritics, and one bad card poisons months of reviews — so
/// nothing reaches the deck until it has been looked at.
struct ImportView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(\.dismiss) private var dismiss

    let onImported: () -> Void

    @State private var selection: [PhotosPickerItem] = []
    @State private var candidates: [ImportCandidate] = []
    @State private var stage: Stage?
    @State private var isSaving = false
    @State private var result: String?
    @State private var scanTask: Task<Void, Never>?

    /// What the spinner is waiting on. Reading a screenshot and asking for the
    /// missing translations are different waits, and the second one can be long
    /// enough that "Reading screenshots…" would look stuck.
    private enum Stage {
        case reading
        case translating

        var label: String {
            switch self {
            case .reading: "Reading screenshots…"
            case .translating: "Filling in the missing translations…"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let stage {
                    ProgressView(stage.label)
                } else if candidates.isEmpty {
                    empty
                } else {
                    review
                }
            }
            .navigationTitle("Import from screenshots")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if !candidates.isEmpty {
                        Button("Add \(selectedCount)") { Task { await save() } }
                            .disabled(selectedCount == 0 || isSaving)
                    }
                }
            }
            .onChange(of: selection) { _, items in
                // Cancel rather than race. Two scans writing to the same array
                // used to lose whatever the learner had already corrected.
                scanTask?.cancel()
                scanTask = Task { await scan(items) }
            }
            .onDisappear { scanTask?.cancel() }
        }
    }

    private var selectedCount: Int { candidates.filter(\.isSelected).count }

    private var empty: some View {
        ContentUnavailableView {
            Label("Import your word list", systemImage: "text.viewfinder")
        } description: {
            Text(
                "Screenshot your Duolingo word list — several overlapping shots are fine, duplicates are removed automatically."
            )
        } actions: {
            PhotosPicker(
                selection: $selection, maxSelectionCount: 20, matching: .screenshots
            ) {
                Text("Choose screenshots")
            }
            .buttonStyle(.borderedProminent)

            if let result {
                Text(result).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private var review: some View {
        List {
            if let result {
                Section {
                    Label(result, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.footnote)
                }
            }

            Section {
                ForEach($candidates) { $candidate in
                    HStack(alignment: .top, spacing: 12) {
                        Button {
                            candidate.isSelected.toggle()
                        } label: {
                            Image(
                                systemName: candidate.isSelected
                                    ? "checkmark.circle.fill" : "circle"
                            )
                            .foregroundStyle(candidate.isSelected ? Color.accentColor : .secondary)
                        }
                        .buttonStyle(.plain)

                        VStack(spacing: 4) {
                            TextField("Word", text: $candidate.lemma)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                            Divider()
                            TextField("Translation", text: $candidate.gloss)

                            // Shown, not hidden behind a hover: `.help` does
                            // nothing on iOS, so the old warning triangle never
                            // explained itself to anyone.
                            if let note = note(for: candidate) {
                                Text(note)
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            } header: {
                Text(header)
            } footer: {
                Text(
                    "Unticked rows didn't look like vocabulary. Tick anything that was rejected by mistake."
                )
            }
        }
    }

    private var header: String {
        let skipped = candidates.count - selectedCount
        let found = "\(candidates.count) found — edit anything that came out wrong"
        return skipped == 0 ? found : "\(found). \(skipped) unticked."
    }

    private func note(for candidate: ImportCandidate) -> String? {
        if let caution = candidate.caution { return caution }
        // Said before the learner taps Add, not after: a row that can't be
        // imported should say so while there is still a keyboard on screen.
        if candidate.isSelected, !candidate.isComplete { return "Needs a translation" }
        if candidate.confidence < 0.5 { return "Hard to read — check this one" }
        return nil
    }

    // MARK: - Scanning

    private func scan(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        stage = .reading
        result = nil
        defer { stage = nil }

        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data)
            {
                images.append(image)
            }
        }

        let found: [ImportCandidate]
        do {
            found = try await ScreenshotImporter.candidates(
                from: images,
                sourceLang: settings.sourceLang,
                targetLang: settings.targetLang
            )
        } catch {
            result = error.localizedDescription
            return
        }
        guard !Task.isCancelled else { return }

        // Merge rather than replace: picking a second batch of screenshots used
        // to throw away every correction already typed into the first.
        candidates = ScreenshotImporter.dedupe(candidates + found)
        if candidates.isEmpty {
            result = "Couldn't find any words in those images."
            return
        }

        stage = .translating
        await fillMissingGlosses()
    }

    /// Asks for the translations Duolingo didn't print.
    ///
    /// Only for the rows that are actually going to be imported: the unticked
    /// ones are furniture and offcuts, and translating them would be paying for
    /// answers nobody wants.
    private func fillMissingGlosses() async {
        let slots = candidates.indices.filter {
            candidates[$0].isSelected && candidates[$0].gloss.isEmpty
                && !candidates[$0].lemma.isEmpty
        }
        guard !slots.isEmpty else { return }

        let translator = LocalTranslator(
            client: settings.isConfigured ? settings.makeClient() : nil,
            sourceLang: settings.sourceLang,
            targetLang: settings.targetLang
        )
        let translations = await translator.translate(
            slots.map { candidates[$0].lemma },
            // The word is in the language being learnt, so the side to fill is
            // the learner's own.
            into: .source
        )
        guard !Task.isCancelled else { return }

        for (slot, translation) in zip(slots, translations) {
            guard let translation else { continue }
            candidates[slot].gloss = translation
        }

        let unanswered = zip(slots, translations).filter { $0.1 == nil }.count
        if unanswered > 0 {
            result =
                "Couldn't translate \(unanswered) of them — fill those in, or leave them unticked."
        }
    }

    // MARK: - Saving

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        // A word with no translation has no answer side, and the placeholder
        // this used to send -- "(to fill in)" -- became the answer permanently,
        // because nothing ever went back to replace it. Held back rather than
        // sent half-formed, and left on the review screen to be typed.
        let ready = candidates.filter { $0.isSelected && $0.isComplete }
        let heldBack = selectedCount - ready.count
        let words = ready.map {
            WordCreate(
                lemma: $0.lemma.trimmingCharacters(in: .whitespaces),
                nativeGloss: $0.gloss.trimmingCharacters(in: .whitespaces),
                notes: nil,
                source: .ocr
            )
        }

        guard !words.isEmpty else {
            result = "Every ticked row is still missing its translation."
            return
        }

        do {
            let outcome = try await settings.makeClient().addWords(words)
            onImported()

            // Leave on screen anything the learner would want to act on, and
            // get out of the way otherwise. Overlapping screenshots are the
            // suggested way to use this, so "skipped 12 duplicates" is a normal
            // outcome worth seeing rather than an error -- and the rows without
            // a translation are still sitting there waiting to be typed.
            guard outcome.duplicates.isEmpty, heldBack == 0 else {
                candidates = candidates.filter { $0.isSelected && !$0.isComplete }
                result = summary(
                    added: outcome.created.count,
                    skipped: outcome.duplicates.count,
                    heldBack: heldBack
                )
                return
            }
            dismiss()
        } catch {
            // Rendered above the review list, which is what is on screen at
            // this point -- the old message went to the empty state nobody
            // could see.
            result = error.localizedDescription
        }
    }

    private func summary(added: Int, skipped: Int, heldBack: Int) -> String {
        var parts = ["Added \(added)"]
        if skipped > 0 { parts.append("skipped \(skipped) already in your deck") }
        if heldBack > 0 {
            parts.append(
                heldBack == 1 ? "1 still needs both sides" : "\(heldBack) still need both sides"
            )
        }
        return parts.joined(separator: ", ") + "."
    }
}
