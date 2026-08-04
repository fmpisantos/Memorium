import Foundation
import Testing

@testable import Memorium

/// Which way round to translate is the one piece of pure logic in the
/// on-device path, and it is the one that fails silently: get it backwards and
/// the app confidently writes a Spanish word into the English side of the card.
/// The server has the same swap in `translate_prompt`; these keep the two
/// honest about agreeing.
@Suite("Translation direction")
struct TranslationDirectionTests {
    private let source = "en-US"
    private let target = "es-ES"

    @Test("Filling the target side translates out of the learner's language")
    func intoTarget() {
        let pair = LocalTranslator.languages(into: .target, source: source, target: target)

        #expect(pair.from == "en-US")
        #expect(pair.to == "es-ES")
    }

    @Test("Filling the source side translates back into the learner's language")
    func intoSource() {
        let pair = LocalTranslator.languages(into: .source, source: source, target: target)

        #expect(pair.from == "es-ES")
        #expect(pair.to == "en-US")
    }

    @Test("The two directions are exact opposites")
    func directionsAreSymmetric() {
        let forward = LocalTranslator.languages(into: .target, source: source, target: target)
        let back = LocalTranslator.languages(into: .source, source: source, target: target)

        #expect(forward.from == back.to)
        #expect(forward.to == back.from)
    }

    @Test("A pair with no language chosen is reported as unsupported, not ready")
    func emptyPairIsUnsupported() async {
        let status = await LocalTranslator.status(from: "", to: "es-ES")

        guard case .unsupported = status else {
            Issue.record("An unset language pair must not report as translatable")
            return
        }
    }
}
