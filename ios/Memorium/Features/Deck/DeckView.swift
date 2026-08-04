import SwiftUI

struct DeckView: View {
    @Environment(AppSettings.self) private var settings

    @State private var words: [Word] = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingAdd = false
    @State private var showingImport = false
    @State private var editing: Word?
    /// A failed delete, shown as an alert. Separate from `error`, which
    /// replaces the whole list when the deck itself cannot be loaded.
    @State private var actionError: String?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && words.isEmpty {
                    ProgressView()
                } else if let error, words.isEmpty {
                    ContentUnavailableView {
                        Label("Can't load your deck", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try again") { Task { await load() } }
                    }
                } else if words.isEmpty {
                    ContentUnavailableView {
                        Label("No words yet", systemImage: "text.book.closed")
                    } description: {
                        Text("Add words as you meet them in Duolingo.")
                    } actions: {
                        Button("Add a word") { showingAdd = true }
                            .buttonStyle(.borderedProminent)
                    }
                } else {
                    list
                }
            }
            .navigationTitle("Deck")
            .searchable(text: $search, prompt: "Search words")
            .onChange(of: search) { _, _ in Task { await load() } }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Add a word", systemImage: "plus") { showingAdd = true }
                        Button("Import from screenshots", systemImage: "text.viewfinder") {
                            showingImport = true
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) {
                AddWordView { _ in Task { await load() } }
            }
            .sheet(item: $editing) { word in
                AddWordView(editing: word) { saved in
                    // The row changes as the sheet closes, rather than a
                    // round trip later: the server hands back the word it
                    // saved, so there is nothing left to ask it for.
                    if let saved { replace(saved) }
                    // Still reloaded, because an edit can move a word out of
                    // the current search or change how it sorts.
                    Task { await load() }
                }
            }
            .sheet(isPresented: $showingImport) {
                ImportView { Task { await load() } }
            }
            .alert(
                "Couldn't remove that word",
                isPresented: Binding(
                    get: { actionError != nil },
                    set: { if !$0 { actionError = nil } }
                ),
                presenting: actionError
            ) { _ in
                Button("OK", role: .cancel) {}
            } message: { detail in
                Text(detail)
            }
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private var list: some View {
        List {
            Section {
                ForEach(words) { word in
                    WordRow(word: word)
                        // Full swipe is off on purpose: with Delete sitting
                        // outermost, a quick flick would throw a word away
                        // when the intent was to reach Edit.
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button(role: .destructive) {
                                delete(word)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }

                            Button {
                                editing = word
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            .tint(.accentColor)
                        }
                }
            } footer: {
                Text("\(words.count) word\(words.count == 1 ? "" : "s")")
            }
        }
    }

    private func load() async {
        guard settings.isConfigured else {
            error = "Set your server address and token in Settings."
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            words = try await settings.makeClient().words(search: search.isEmpty ? nil : search)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Writes an edited word over the copy on screen. A word missing from the
    /// list is not an error: the search may have changed while the sheet was
    /// open, and the reload that follows knows where it belongs.
    private func replace(_ word: Word) {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        words[index] = word
    }

    /// Removes the row straight away, then confirms it with the server. A
    /// failure puts the word back rather than leaving the list claiming a
    /// deletion that never happened -- offline is the common case here, and it
    /// would otherwise reappear unexplained at the next refresh.
    private func delete(_ word: Word) {
        guard let index = words.firstIndex(where: { $0.id == word.id }) else { return }
        words.remove(at: index)
        Task {
            do {
                try await settings.makeClient().deleteWord(id: word.id)
            } catch let APIError.server(status, _) where status == 404 {
                // Already gone on the server; the list is now right.
            } catch {
                // Only this word goes back, at the place it came from: a
                // second delete may have landed while this one was in flight,
                // and restoring a whole snapshot would undo that one too.
                words.insert(word, at: min(index, words.count))
                actionError = "\(word.display) is still in your deck. \(error.localizedDescription)"
            }
        }
    }
}

private struct WordRow: View {
    let word: Word

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(word.display)
                    .font(.headline)
                Spacer()
                statusBadge
            }
            Text(word.nativeGloss)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let notes = word.notes, !notes.isEmpty {
                Text(notes)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            if !word.cards.isEmpty {
                HStack(spacing: 10) {
                    ForEach(word.cards) { card in
                        Label(
                            card.kind.rawValue.prefix(4).capitalized,
                            systemImage: card.isLeech ? "exclamationmark.triangle.fill" : "circle.fill"
                        )
                        .font(.caption2)
                        .foregroundStyle(card.isLeech ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
                        .labelStyle(.titleAndIcon)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch word.enrichmentStatus {
        case .done:
            EmptyView()
        case .failed:
            Image(systemName: "exclamationmark.icloud")
                .font(.caption)
                .foregroundStyle(.orange)
                .accessibilityLabel("Content generation failed")
        default:
            ProgressView()
                .controlSize(.mini)
                .accessibilityLabel("Generating examples")
        }
    }
}
