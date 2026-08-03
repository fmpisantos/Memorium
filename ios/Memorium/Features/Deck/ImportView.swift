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
    @State private var isScanning = false
    @State private var isSaving = false
    @State private var result: String?

    var body: some View {
        NavigationStack {
            Group {
                if isScanning {
                    ProgressView("Reading screenshots…")
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
                Task { await scan(items) }
            }
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
            Section {
                ForEach($candidates) { $candidate in
                    HStack(spacing: 12) {
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
                        }

                        if candidate.confidence < 0.5 {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                                .help("Low confidence — check this one")
                        }
                    }
                }
            } header: {
                Text("\(candidates.count) found — edit anything that came out wrong")
            } footer: {
                Text(
                    "Rows without a translation still import; the missing side gets filled in when examples are generated."
                )
            }
        }
    }

    private func scan(_ items: [PhotosPickerItem]) async {
        guard !items.isEmpty else { return }
        isScanning = true
        defer { isScanning = false }

        var images: [UIImage] = []
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self),
               let image = UIImage(data: data)
            {
                images.append(image)
            }
        }

        candidates = await ScreenshotImporter.candidates(
            from: images,
            sourceLang: settings.sourceLang,
            targetLang: settings.targetLang
        )
        if candidates.isEmpty {
            result = "Couldn't find any words in those images."
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }

        let words = candidates.filter(\.isSelected).map {
            WordCreate(
                lemma: $0.lemma.trimmingCharacters(in: .whitespaces),
                nativeGloss: $0.gloss.trimmingCharacters(in: .whitespaces).isEmpty
                    ? "(to fill in)"
                    : $0.gloss.trimmingCharacters(in: .whitespaces),
                notes: nil
            )
        }
        .filter { !$0.lemma.isEmpty }

        do {
            let outcome = try await settings.makeClient().addWords(words)
            onImported()
            result = "Added \(outcome.created.count), skipped \(outcome.duplicates.count) already in your deck."
            dismiss()
        } catch {
            result = error.localizedDescription
        }
    }
}
