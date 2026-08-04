import Foundation
import UIKit
import Vision

/// Why a screenshot could not be read. Every case carries a whole sentence,
/// like `APIError`, because it is shown to the learner on its own.
enum ScreenshotImportError: LocalizedError {
    /// Vision has no model for either side of the pair, so there is nothing to
    /// recognise the page with.
    case noRecognisableLanguage(target: String)
    case recognitionFailed(String)

    var errorDescription: String? {
        switch self {
        case .noRecognisableLanguage(let target):
            "Your device can't read \(target) text from an image, and English isn't set as your other language either."
        case .recognitionFailed(let reason):
            "Couldn't read that screenshot: \(reason)"
        }
    }
}

/// Runs Vision over screenshots and hands the lines to `WordListLayout`.
///
/// Everything here is I/O and language configuration; the geometry that decides
/// which line is a word and which is its translation lives in `WordListLayout`,
/// where it can be tested without an image.
@MainActor
enum ScreenshotImporter {
    static func candidates(
        from images: [UIImage],
        sourceLang: String,
        targetLang: String
    ) async throws -> [ImportCandidate] {
        let languages = recognitionLanguages(sourceLang: sourceLang, targetLang: targetLang)
        guard !languages.tags.isEmpty else {
            throw ScreenshotImportError.noRecognisableLanguage(target: targetLang)
        }

        var all: [ImportCandidate] = []
        for image in images {
            all += try extract(from: image, languages: languages)
        }
        return dedupe(all)
    }

    // MARK: - Which languages Vision can actually read

    private struct Recognition {
        let tags: [String]
        /// Whether Vision holds a model for the language being *learnt*.
        let coversTarget: Bool
    }

    /// Narrows the learner's pair down to what Vision ships models for.
    ///
    /// Handing Vision a tag it does not support makes the whole request throw,
    /// which used to surface as "couldn't find any words" — the same message a
    /// blank screenshot produces. Vision's list is much shorter than the twenty
    /// languages this app offers, so a Norwegian or Polish learner hit that on
    /// every import.
    private static func recognitionLanguages(sourceLang: String, targetLang: String)
        -> Recognition
    {
        let supported = supportedLanguages()
        let target = supported.match(targetLang)
        let source = supported.match(sourceLang)
        return Recognition(
            tags: [target, source].compactMap { $0 },
            coversTarget: target != nil
        )
    }

    private static func supportedLanguages() -> [String] {
        // Asked of a request configured the same way the real one is: the list
        // depends on the recognition level.
        let probe = VNRecognizeTextRequest()
        probe.recognitionLevel = .accurate
        return (try? probe.supportedRecognitionLanguages()) ?? []
    }

    // MARK: - Vision

    private static func extract(
        from image: UIImage, languages: Recognition
    ) throws -> [ImportCandidate] {
        guard let cgImage = image.cgImage else { return [] }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages.tags
        // Correction is only ever an improvement when Vision has the language
        // it is correcting towards. Left on for a pair it doesn't cover, it
        // rewrites the word being learnt into the nearest thing in the other
        // language -- which is how "også" came back as "also".
        request.usesLanguageCorrection = languages.coversTarget

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw ScreenshotImportError.recognitionFailed(error.localizedDescription)
        }

        let lines = (request.results ?? []).compactMap { observation -> TextLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return line(from: candidate, fallback: observation.boundingBox)
        }

        return WordListLayout.candidates(from: lines)
    }

    /// Reads one line, with the row's speaker button taken off the front.
    ///
    /// Every row on this screen opens with a little blue speaker, and Vision
    /// reads it as text: sometimes as a line of its own ("4)", "•)"), and
    /// sometimes glued to the word beside it ("•) stor", "4) by"). Left alone
    /// the glued ones start half an inch further left than every other line in
    /// the list, which is enough to get the word thrown out as furniture — and
    /// a word missing from the middle of the list takes the spacing that pairs
    /// translations to words down with it.
    private static func line(
        from candidate: VNRecognizedText, fallback: CGRect
    ) -> TextLine? {
        let text = candidate.string
        guard let start = wordStart(in: text) else { return nil }
        let trimmed = String(text[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Ask Vision where the *word* sits rather than where the button does,
        // so the line lines up with the column it belongs to.
        let box =
            start == text.startIndex
            ? fallback
            : (try? candidate.boundingBox(for: start..<text.endIndex))?.boundingBox ?? fallback

        return TextLine(text: trimmed, box: box, confidence: candidate.confidence)
    }

    /// Where the real text starts, past any leading icon.
    ///
    /// Only a short opening token with no letters in it counts as an icon, so
    /// "132 words" and "START +10 XP" are left whole for the layout parser to
    /// judge on their position, as furniture should be.
    private static func wordStart(in text: String) -> String.Index? {
        guard !text.isEmpty else { return nil }
        guard let space = text.firstIndex(where: \.isWhitespace) else { return text.startIndex }

        let opening = text[text.startIndex..<space]
        guard opening.count <= 2, !opening.contains(where: \.isLetter) else {
            return text.startIndex
        }
        let rest = text[space...].drop(while: \.isWhitespace)
        return rest.isEmpty ? nil : rest.startIndex
    }

    // MARK: - Across screenshots

    /// Overlapping screenshots of a scrolling list are expected, not an error.
    ///
    /// Where the same word turns up twice, the better reading wins rather than
    /// the first: a word caught mid-scroll at the top of one screenshot, with
    /// its translation sheared off, should give way to the clean copy from the
    /// screenshot that had room for both.
    static func dedupe(_ candidates: [ImportCandidate]) -> [ImportCandidate] {
        var order: [String] = []
        var best: [String: ImportCandidate] = [:]

        for candidate in candidates {
            let key = candidate.lemma.importKey
            guard !key.isEmpty else { continue }
            guard let existing = best[key] else {
                order.append(key)
                best[key] = candidate
                continue
            }
            if isBetter(candidate, than: existing) { best[key] = candidate }
        }
        return order.compactMap { best[$0] }
    }

    private static func isBetter(_ lhs: ImportCandidate, than rhs: ImportCandidate) -> Bool {
        if lhs.isSelected != rhs.isSelected { return lhs.isSelected }
        if lhs.gloss.isEmpty != rhs.gloss.isEmpty { return !lhs.gloss.isEmpty }
        return lhs.confidence > rhs.confidence
    }
}

extension String {
    /// The form two spellings are compared in to decide they are the same word.
    ///
    /// Case folding rather than lowercasing, to agree with the server's
    /// `casefold()` (`models.py`) about which words are duplicates -- otherwise
    /// the app thinks it sent two words and the server thinks it received one.
    var importKey: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: .caseInsensitive, locale: nil)
    }
}

extension [String] {
    /// Vision names its languages "en-US", "de-DE", "zh-Hans"; settings hold
    /// BCP-47 tags that may or may not carry a region. Prefer an exact hit,
    /// then fall back to the language subtag so "en-GB" still finds "en-US".
    fileprivate func match(_ tag: String) -> String? {
        guard !tag.isEmpty else { return nil }
        if let exact = first(where: { $0.caseInsensitiveCompare(tag) == .orderedSame } ) {
            return exact
        }
        let language = tag.split(separator: "-").first.map(String.init) ?? tag
        return first { $0.split(separator: "-").first.map(String.init) == language }
    }
}
