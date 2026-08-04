import CoreGraphics
import Foundation

/// A word candidate lifted out of a screenshot, before the learner confirms it.
struct ImportCandidate: Identifiable, Hashable {
    let id = UUID()
    var lemma: String
    var gloss: String
    var confidence: Float
    var isSelected: Bool = true
    /// Why this row arrived unticked, or nil when it looks clean.
    ///
    /// Shown on the row rather than kept internal: a parser that silently drops
    /// what it dislikes is indistinguishable from one that never saw the word,
    /// and the learner is the only one who can tell those apart.
    var caution: String?

    /// Whether both sides are there. A card needs a question and an answer, so
    /// a half-filled row waits on the review screen rather than going into the
    /// deck to be asked with nothing to say. Named to match `WordDraft`, which
    /// gates manual entry the same way.
    var isComplete: Bool {
        !lemma.trimmingCharacters(in: .whitespaces).isEmpty
            && !gloss.trimmingCharacters(in: .whitespaces).isEmpty
    }
}

/// One OCR line with everything the layout parser needs.
///
/// Mirrors Vision's output but carries no Vision types, so a test can build a
/// page of lines by hand and read the parser's mind without an image.
struct TextLine: Sendable, Equatable {
    let text: String
    /// Vision-normalised: origin bottom-left, so `maxY` is the *top* edge.
    let box: CGRect
    let confidence: Float
}

/// Turns recognised lines into word/translation pairs.
///
/// Deliberately *not* keyed to Duolingo's pixels, which vary by course and get
/// redesigned. It works from what the screenshots actually measure: one column
/// of rows sharing a left edge, each row a word with — only sometimes — its
/// translation tucked directly underneath. The two facts that matter are that
/// the gap inside a row is several times smaller than the gap between rows, and
/// that page furniture does not line up with the column.
enum WordListLayout {
    /// How far two lines' left edges may differ and still count as one column.
    ///
    /// Normalised. Measured on the fixtures, the list's own left edges spread
    /// about 2% of the image width -- Vision puts a "k" a little further left
    /// than an "o" -- while the nearest piece of furniture is 5% away. This
    /// sits between the two.
    private static let leftEdgeTolerance: CGFloat = 0.035

    /// How much bigger the between-rows gap must be than the inside-a-row gap
    /// before the split between them is believed at all.
    private static let separationRatio: CGFloat = 1.5

    /// The largest a gap can be, relative to a line's height, and still be the
    /// space between a word and its own translation.
    private static let intraGapCeiling: CGFloat = 1.2

    static let chromeCaution = "Looks like part of the app, not a word"
    static let strandedCaution = "Looks like a translation whose word was cut off"

    static func candidates(from lines: [TextLine]) -> [ImportCandidate] {
        let usable = lines.filter { isPlausibleWord($0.text) }
        guard !usable.isEmpty else { return [] }

        let split = splitColumnFromChrome(usable)
        return entries(in: split.column)
            + split.chrome.map {
                ImportCandidate(
                    lemma: $0.text,
                    gloss: "",
                    confidence: $0.confidence,
                    isSelected: false,
                    caution: chromeCaution
                )
            }
    }

    // MARK: - Line-level rejects

    /// The few strings that cannot be vocabulary in any language.
    ///
    /// Kept this short on purpose. The old list held ordinary words like "all",
    /// "back", "done" and "start", which quietly deleted real vocabulary from
    /// anyone learning English; geometry is what separates furniture from
    /// words, not a wordlist.
    private static let furniture: Set<String> = ["practice hub", "match madness"]

    /// "132 words" — the heading above the list, and the one piece of furniture
    /// that shares its left edge with the column on some screens.
    private static func isWordCount(_ text: String) -> Bool {
        let lowered = text.lowercased()
        for suffix in [" words", " word"] where lowered.hasSuffix(suffix) {
            let count = lowered.dropLast(suffix.count)
            return !count.isEmpty
                && count.allSatisfy { $0.isNumber || $0 == "," || $0 == "." || $0 == " " }
        }
        return false
    }

    static func isPlausibleWord(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 60 else { return false }
        if furniture.contains(text.lowercased()) { return false }
        if isWordCount(text) { return false }
        // Pure numbers are the clock, the battery, XP counters and streak days.
        if text.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isWhitespace }) { return false }
        return text.contains { $0.isLetter }
    }

    // MARK: - Finding the column

    /// Separates the list from everything around it by left edge.
    ///
    /// The rows of a word list all start at the same x; the title, the count,
    /// the sort control and the big call-to-action button each start somewhere
    /// else. Clustering on that one number pulls the list out without needing
    /// to know how tall the header is — which is just as well, since it fills
    /// 40% of the screen at the top of the list and almost none of it further
    /// down.
    private static func splitColumnFromChrome(
        _ lines: [TextLine]
    ) -> (column: [TextLine], chrome: [TextLine]) {
        guard !lines.isEmpty else { return ([], []) }

        // Mode-seeking: find the left edge with the most lines gathered around
        // it, and take everything within reach of that. Growing a cluster
        // leftmost-first instead anchors the window on the outermost line
        // rather than the middle of the column, so it reaches only half as far
        // to the right -- which is how a list whose last rows sat a hair
        // further right than the rest lost them to a cluster of their own.
        let neighbourhoods = lines.indices.map { index in
            lines.indices.filter {
                abs(lines[$0].box.minX - lines[index].box.minX) <= leftEdgeTolerance
            }
        }
        guard
            let winner = neighbourhoods.max(by: { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return verticalExtent(of: lhs, in: lines) < verticalExtent(of: rhs, in: lines)
            })
        else { return ([], lines) }

        let column = Set(winner)
        return (
            column: winner.map { lines[$0] },
            chrome: lines.indices.filter { !column.contains($0) }.map { lines[$0] }
        )
    }

    private static func verticalExtent(of cluster: [Int], in lines: [TextLine]) -> CGFloat {
        let tops = cluster.map { lines[$0].box.maxY }
        let bottoms = cluster.map { lines[$0].box.minY }
        guard let top = tops.max(), let bottom = bottoms.min() else { return 0 }
        return top - bottom
    }

    // MARK: - Grouping the column into rows

    private static func entries(in column: [TextLine]) -> [ImportCandidate] {
        guard !column.isEmpty else { return [] }
        // Vision's origin is bottom-left, so descending maxY walks the page
        // from top to bottom.
        let topToBottom = column.sorted { $0.box.maxY > $1.box.maxY }
        let rows = rows(in: topToBottom)
        let stranded = strandedGlosses(among: rows)

        return zip(rows, stranded).map { row, isStranded in
            // The first line of a row is the word and anything below it is the
            // translation, wrapped or not. Nothing here assumes how many lines
            // a row has: on this screen roughly half the words carry no
            // translation at all, which is exactly what the old
            // two-lines-per-row rule got wrong.
            let gloss = row.dropFirst().map(\.text).joined(separator: " ")
            return ImportCandidate(
                lemma: row[0].text,
                gloss: gloss,
                confidence: row.map(\.confidence).min() ?? 0,
                isSelected: !isStranded,
                caution: isStranded ? strandedCaution : nil
            )
        }
    }

    private static func rows(in topToBottom: [TextLine]) -> [[TextLine]] {
        guard topToBottom.count > 1 else { return topToBottom.map { [$0] } }

        let gaps = zip(topToBottom, topToBottom.dropFirst()).map { above, below in
            max(0, above.box.minY - below.box.maxY)
        }
        guard let threshold = rowBreakThreshold(gaps: gaps, lines: topToBottom) else {
            return topToBottom.map { [$0] }
        }

        var rows: [[TextLine]] = [[topToBottom[0]]]
        for (index, gap) in gaps.enumerated() {
            if gap > threshold { rows.append([]) }
            rows[rows.count - 1].append(topToBottom[index + 1])
        }
        return rows
    }

    /// The gap above which a line belongs to the next row rather than this one,
    /// or nil when the page gives no reason to believe any line is a translation.
    private static func rowBreakThreshold(gaps: [CGFloat], lines: [TextLine]) -> CGFloat? {
        guard gaps.count >= 2, let smallest = gaps.min(), let largest = gaps.max(),
            largest > smallest
        else { return nil }

        // 1-D 2-means seeded at the extremes. The distribution is tiny and, on
        // a real word list, strongly separated -- measured on the fixtures the
        // gap inside a row is about a fifth of the gap between rows -- so a
        // handful of passes settles it.
        var low = smallest
        var high = largest
        for _ in 0..<12 {
            let split = (low + high) / 2
            let lower = gaps.filter { $0 <= split }
            let upper = gaps.filter { $0 > split }
            guard !lower.isEmpty, !upper.isEmpty else { break }
            low = lower.reduce(0, +) / CGFloat(lower.count)
            high = upper.reduce(0, +) / CGFloat(upper.count)
        }

        // Two guards against reading structure into noise. A screenshot where
        // every word happens to lack a translation has only between-row gaps,
        // and k-means will still cut them in half -- but the halves land close
        // together, and the smaller one is far too big to be the space inside a
        // row. Either check failing means every line is its own word.
        guard high >= low * separationRatio else { return nil }
        guard low <= median(lines.map(\.box.height)) * intraGapCeiling else { return nil }
        return (low + high) / 2
    }

    /// Flags the top row when it is a translation with no word above it.
    ///
    /// A screenshot taken mid-scroll can open on a row whose word is sheared
    /// off above the fold, leaving its translation to be read as vocabulary.
    /// Only the top row can be in that state -- anywhere else the word is right
    /// there above it -- and asking the question of every row is how "bor", a
    /// perfectly good word that happens to be set slightly short, came back
    /// flagged.
    ///
    /// Rows that do have two lines say, on this exact screenshot, how tall a
    /// word is and how tall a translation is; the lone top line is then
    /// measured against both. With no such row there is no calibration, and the
    /// parser keeps its opinion to itself rather than guessing.
    private static func strandedGlosses(among rows: [[TextLine]]) -> [Bool] {
        var flags = rows.map { _ in false }
        guard let top = rows.first, top.count == 1 else { return flags }

        let paired = rows.filter { $0.count > 1 }
        let wordHeights = paired.map { $0[0].box.height }
        let glossHeights = paired.flatMap { $0.dropFirst().map(\.box.height) }
        guard !wordHeights.isEmpty, !glossHeights.isEmpty else { return flags }

        let wordHeight = median(wordHeights)
        let glossHeight = median(glossHeights)
        // Only worth asking when the two sizes are actually distinguishable.
        guard wordHeight > glossHeight * 1.08 else { return flags }

        let height = top[0].box.height
        flags[0] = abs(height - glossHeight) < abs(height - wordHeight)
        return flags
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
