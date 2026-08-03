import Foundation
import UIKit
import Vision

/// A word candidate lifted out of a screenshot, before the learner confirms it.
struct ImportCandidate: Identifiable, Hashable {
    let id = UUID()
    var lemma: String
    var gloss: String
    var confidence: Float
    var isSelected: Bool = true
}

/// Pulls word/translation pairs out of screenshots.
///
/// Deliberately *not* a Duolingo-specific parser. The word list lives in
/// Practice Hub, varies by course, and gets redesigned; anything keyed to its
/// exact layout would break silently. This works from geometry instead --
/// recognise every line with its bounding box, then infer whether the page is
/// one column or two.
@MainActor
enum ScreenshotImporter {
    /// Lines that are page furniture rather than vocabulary.
    private static let chrome: Set<String> = [
        "words", "practice", "practice hub", "learn", "review", "done", "back",
        "search", "all", "recent", "sort", "filter", "streak", "xp", "hearts",
        "continue", "start", "skip", "settings", "profile", "leagues", "shop",
    ]

    static func candidates(
        from images: [UIImage],
        sourceLang: String,
        targetLang: String
    ) async -> [ImportCandidate] {
        var all: [ImportCandidate] = []
        for image in images {
            all += await extract(from: image, sourceLang: sourceLang, targetLang: targetLang)
        }
        return dedupe(all)
    }

    private static func extract(
        from image: UIImage, sourceLang: String, targetLang: String
    ) async -> [ImportCandidate] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        // Both languages: the screenshot has the target word next to its
        // translation, and telling Vision only one of them mangles the other.
        request.recognitionLanguages = [targetLang, sourceLang]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return []
        }

        let observations = (request.results ?? []).compactMap { observation -> Line? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard isPlausibleWord(text) else { return nil }
            return Line(
                text: text,
                box: observation.boundingBox,
                confidence: candidate.confidence
            )
        }

        return pair(observations)
    }

    private struct Line {
        let text: String
        let box: CGRect
        let confidence: Float
    }

    private static func isPlausibleWord(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 60 else { return false }
        if chrome.contains(text.lowercased()) { return false }
        // Pure numbers are XP counters and streak days, never vocabulary.
        if text.allSatisfy({ $0.isNumber || $0.isPunctuation || $0.isWhitespace }) { return false }
        return text.contains { $0.isLetter }
    }

    /// Decide between a two-column layout (word | translation) and a single
    /// column, then pair lines accordingly.
    private static func pair(_ lines: [Line]) -> [ImportCandidate] {
        guard lines.count >= 2 else {
            return lines.map {
                ImportCandidate(lemma: $0.text, gloss: "", confidence: $0.confidence)
            }
        }

        // Cluster on the horizontal midpoint of each line. Two well-separated
        // clusters means two columns.
        let midpoints = lines.map { $0.box.midX }
        let overallMid = (midpoints.min()! + midpoints.max()!) / 2
        let left = lines.filter { $0.box.midX <= overallMid }
        let right = lines.filter { $0.box.midX > overallMid }

        let looksTwoColumn =
            !left.isEmpty && !right.isEmpty
            && Double(min(left.count, right.count)) / Double(max(left.count, right.count)) > 0.6

        if looksTwoColumn {
            // Vision's normalised coordinates put the origin bottom-left, so
            // sorting by descending maxY walks the page top to bottom.
            let leftSorted = left.sorted { $0.box.maxY > $1.box.maxY }
            let rightSorted = right.sorted { $0.box.maxY > $1.box.maxY }
            return zip(leftSorted, rightSorted).map { word, translation in
                ImportCandidate(
                    lemma: word.text,
                    gloss: translation.text,
                    confidence: min(word.confidence, translation.confidence)
                )
            }
        }

        // Single column: assume alternating word / translation lines, which is
        // how stacked list rows read. The review screen exists precisely
        // because this guess is sometimes wrong.
        let sorted = lines.sorted { $0.box.maxY > $1.box.maxY }
        return stride(from: 0, to: sorted.count, by: 2).map { index in
            let word = sorted[index]
            let translation = index + 1 < sorted.count ? sorted[index + 1] : nil
            return ImportCandidate(
                lemma: word.text,
                gloss: translation?.text ?? "",
                confidence: min(word.confidence, translation?.confidence ?? word.confidence)
            )
        }
    }

    /// Overlapping screenshots of a scrolling list are expected, not an error.
    private static func dedupe(_ candidates: [ImportCandidate]) -> [ImportCandidate] {
        var seen = Set<String>()
        var out: [ImportCandidate] = []
        for candidate in candidates {
            let key = candidate.lemma.lowercased()
            guard !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(candidate)
        }
        return out
    }
}
