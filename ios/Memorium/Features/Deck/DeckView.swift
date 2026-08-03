import SwiftUI

struct DeckView: View {
    @Environment(AppSettings.self) private var settings

    @State private var words: [Word] = []
    @State private var search = ""
    @State private var isLoading = false
    @State private var error: String?
    @State private var showingAdd = false
    @State private var showingImport = false

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
                AddWordView { Task { await load() } }
            }
            .sheet(isPresented: $showingImport) {
                ImportView { Task { await load() } }
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
                }
                .onDelete(perform: delete)
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

    private func delete(at offsets: IndexSet) {
        let targets = offsets.map { words[$0] }
        words.remove(atOffsets: offsets)
        Task {
            for word in targets {
                try? await settings.makeClient().deleteWord(id: word.id)
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
