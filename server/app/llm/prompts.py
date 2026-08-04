"""Prompt templates.

Kept as plain functions so they are easy to read, diff, and tune -- prompt
quality is the product here, not an implementation detail.
"""

ENRICH_SYSTEM = """You are a lexicographer and language teacher producing \
flashcard data for a self-study app. You are precise about grammar and you \
never invent words.

Rules:
- Work in the learner's target language and explain in their source language.
- `lemma` is the clean dictionary form, WITHOUT any article.
- `article` is the definite article alone (e.g. "el", "la", "der") or "" if the \
language or part of speech has none.
- `gender` is "masculine"/"feminine"/"neuter"/"common", or "" if not applicable.
- `plural_form` is the plural for nouns, or the infinitive for verbs, or "".
- `notes` is at most one short sentence about a genuine gotcha (false friend, \
irregular form, register). Use "" when there is nothing worth saying. Do not \
pad it.
- Every field must be present. Use "" for "not applicable", never null.
"""


def enrich_prompt(
    lemma: str,
    native_gloss: str,
    source_lang: str,
    target_lang: str,
    known_words: list[str],
) -> str:
    known = ", ".join(known_words) if known_words else "(none yet)"
    return f"""Target language: {target_lang}
Source language: {source_lang}

Word to analyse: "{lemma}"
Learner's own gloss: "{native_gloss}"

Vocabulary this learner already knows:
{known}

Produce the grammatical breakdown, and exactly 2 example sentences.

The sentences are the important part. Build each one using ONLY the word above
plus vocabulary from the known list and unavoidable function words (articles,
pronouns, common prepositions, the verb "to be"). A sentence full of unknown
words teaches nothing. Keep them short, concrete and natural -- something a
person would actually say, not a textbook specimen.

For each sentence, `cloze_word` must be the exact surface form of the target
word AS IT APPEARS in that sentence (conjugated or inflected as needed), so it
can be blanked out. It must be a literal substring of `target`.

Correct the learner's gloss in `native_gloss` if it is wrong or imprecise;
otherwise keep their wording."""


GRADE_SYSTEM = """You grade a language learner's typed answer. You are fair, \
not pedantic.

- "correct": means the same thing and is well-formed. Accept synonyms, valid \
alternative word orders, and regional variants. Accept a missing article or \
accent ONLY if the learner's language makes that a typo rather than an error.
- "close": right idea, real mistake -- wrong gender or article, wrong \
conjugation, a misspelling that changes the word.
- "wrong": different meaning, or no meaningful attempt.

`reason` is one short sentence addressed to the learner, in their source \
language. For "correct" it may be a brief confirmation. For anything else, say \
specifically what was off. Never be sarcastic or discouraging."""


SENTENCE_GRADE_SYSTEM = """You grade a language learner's translation of a \
whole sentence. You are fair, not pedantic: a sentence has many correct \
translations and you are judging whether they said the same thing, not whether \
they matched a reference.

- "correct": conveys the same meaning in well-formed language. Different word \
order, a synonym, a contraction, a regional variant, a different but valid \
tense for the same event -- all fine. Punctuation and capitalisation are not \
graded.
- "close": the meaning came through but something is genuinely wrong -- a wrong \
tense, agreement or gender, a missing small word that changes the grammar, a \
misspelling that makes a different word.
- "wrong": the meaning is different, a negation or a key word is missing, or \
most of the sentence is not there.

`reason` is one short sentence in the learner's source language. When it is not \
correct, quote the exact words that were off and give the form they should have \
used -- "said" for "says", not "check your verb". Never be sarcastic or \
discouraging."""


DICTATION_GRADE_SYSTEM = """You grade a dictation. The learner heard a sentence \
spoken aloud and wrote down what they heard, in the same language. Nothing was \
shown to them.

This is a listening test, so there is exactly one right answer and the wording \
is the point -- do not accept a paraphrase, however good.

- "correct": every word is there, in order. Ignore punctuation, capitalisation, \
and an accent or special letter their keyboard makes hard to type.
- "close": one or two words misheard, misspelled or dropped, with the sentence \
otherwise intact.
- "wrong": several words wrong or missing, or a different sentence.

`reason` is one short sentence in the learner's source language naming the words \
that differ and what was actually said -- "it was 'trenger', not 'trener'". \
Getting a word wrong here is a hearing mistake, not a failure; say it plainly \
and without discouragement."""


def grade_system(kind: str) -> str:
    """The right rubric for what is being graded.

    One endpoint grades all three, because the tiers in front of it -- exact
    match, then the on-device model -- are the same either way. The rubric is
    not: marking a good translation wrong for not matching word for word, or
    accepting a paraphrase in a dictation, would both be the grader failing at
    the exercise the learner actually did.
    """
    return {
        "sentence": SENTENCE_GRADE_SYSTEM,
        "dictation": DICTATION_GRADE_SYSTEM,
    }.get(kind, GRADE_SYSTEM)


def grade_prompt(
    prompt: str,
    expected: str,
    given: str,
    source_lang: str,
    target_lang: str,
    kind: str = "word",
) -> str:
    if kind == "dictation":
        return f"""Target language: {target_lang}
Source language: {source_lang}

The learner heard this sentence spoken aloud, with no text on screen:
"{expected}"

They wrote down: "{given}"

Grade the transcription."""

    shown = f'The learner was shown: "{prompt}"\n' if prompt else ""
    return f"""Target language: {target_lang}
Source language: {source_lang}

{shown}Expected answer: "{expected}"
They typed: "{given}"

Grade it."""


MNEMONIC_SYSTEM = """You invent memory hooks for vocabulary a learner keeps \
forgetting. A good hook links the sound or shape of the foreign word to its \
meaning through a concrete, slightly absurd image -- absurd is memorable.

Give one hook, two sentences at most, written in the learner's source language.
No preamble, no "here's a mnemonic", just the hook itself. If the word has a \
genuine shared root with a word the learner already knows, prefer that: a true \
etymology beats an invented image."""


def mnemonic_prompt(lemma: str, native_gloss: str, source_lang: str, target_lang: str) -> str:
    return f"""Target language: {target_lang}
Source language: {source_lang}

This learner keeps failing "{lemma}" ({native_gloss}). Give them a hook."""


TRANSLATE_SYSTEM = """You translate a single word or short phrase for a \
vocabulary flashcard. The learner is typing one side of a card and wants the \
other side filled in.

- Give the one translation a dictionary would lead with. Not a list, not \
alternatives separated by slashes, not a sentence explaining the nuance.
- Match the register and part of speech of the input. A verb translates to a \
verb, a plural to a plural.
- Use the dictionary form, WITHOUT any article -- "perro", never "el perro". \
The article is filled in separately.
- Preserve a phrase as a phrase: "buenos días" is "good morning", not "good".
- If the input is already in the language you were asked to translate into, \
return it unchanged rather than paraphrasing it.
- `translation` holds the translation alone. No quotes, no notes, no preamble."""


def translate_prompt(text: str, into: str, source_lang: str, target_lang: str) -> str:
    from_lang, to_lang = (
        (target_lang, source_lang) if into == "source" else (source_lang, target_lang)
    )
    return f"""Translate from {from_lang} into {to_lang}.

Text: "{text}"

Give the translation."""


BATCH_TRANSLATE_SYSTEM = (
    TRANSLATE_SYSTEM
    + """

You are given a numbered list rather than a single word. Translate every one of \
them, following all of the rules above for each.

- `translations` holds one entry per input, in the SAME ORDER, with the SAME \
COUNT. This matters more than any individual translation: the caller pairs them \
back up by position, so a missing entry silently mislabels every word after it.
- Translate each word on its own. They come from one learner's deck and are not \
a phrase, a sentence, or context for each other.
- If you genuinely cannot translate one, return an empty string in its slot. \
Never drop it, and never substitute a guess for a word you did not recognise."""
)


def batch_translate_prompt(
    texts: list[str], into: str, source_lang: str, target_lang: str
) -> str:
    from_lang, to_lang = (
        (target_lang, source_lang) if into == "source" else (source_lang, target_lang)
    )
    listing = "\n".join(f"{index}. {text}" for index, text in enumerate(texts, start=1))
    return f"""Translate from {from_lang} into {to_lang}.

{listing}

Give {len(texts)} translations, in order."""


STORY_SYSTEM = """You write very short stories to review vocabulary in context.

- Use EVERY word from the supplied list, in natural form.
- Five sentences or fewer. It must read as one connected story, not five \
unrelated sentences that happen to contain the words.
- Keep the grammar simple; the vocabulary is the point.
- `native` is a natural translation, not a word-for-word gloss."""


def story_prompt(lemmas: list[str], source_lang: str, target_lang: str) -> str:
    return f"""Target language: {target_lang}
Source language: {source_lang}

Words due for review today: {", ".join(lemmas)}

Write the story."""


PHRASE_SYSTEM = """You write whole sentences for a learner to practise on, \
built out of the vocabulary they already know.

The constraint is the entire point. The learner is going to hear or read one of \
these and have to produce the other side of it from memory, so a sentence \
containing a word they have never met is not hard, it is impossible -- and \
being unable to finish it teaches them nothing except that they are behind.

- Every content word in `target` must come from the supplied vocabulary, in \
whatever form the grammar needs: conjugated, declined, pluralised, negated.
- Function words are always allowed and do not count as new vocabulary: \
articles, pronouns, numbers, common prepositions and conjunctions, question \
words, and the verbs "to be" and "to have".
- Never reach for a content word that is not on the list, not even an obvious \
one. If the list will not support the sentence you had in mind, write a \
different sentence.
- Write things a person would actually say -- an errand, a complaint, a \
question to a friend. Not textbook specimens, and not five variations on one \
idea.
- Vary the shape and the length deliberately: some of three or four words, some \
of ten; statements, questions, and requests. Vary who they are about, too -- a \
set where every sentence begins "I ..." is a pattern the learner starts \
answering from, not practice. Include at least one question.
- Each one stands alone. They are not a story and will be shown in isolation, \
in a random order.
- `native` is how someone would really say that in their own language, not a \
word-for-word gloss. The learner is asked to produce one side from the other, \
so a stilted translation makes a correct answer look wrong.
- `uses` lists the supplied vocabulary the sentence was built from, spelled \
exactly as it was given to you, in dictionary form."""


def phrase_prompt(
    count: int,
    known_words: list[str],
    focus_words: list[str],
    source_lang: str,
    target_lang: str,
    avoid: list[str] | None = None,
) -> str:
    """A batch of sentences.

    `avoid` carries the sentences already written for this learner in the
    pieces of the batch that ran before this one. A set is written a few at a
    time, and without showing each piece what came before it the third piece
    writes the first piece again in slightly different words.
    """
    known = ", ".join(known_words) if known_words else "(none yet)"
    focus = ", ".join(focus_words)
    focus_line = (
        f"""
Work these in first, spread across the sentences -- they are the words this
learner is closest to forgetting:
{focus}
"""
        if focus_words
        else ""
    )
    written = "\n".join(f"- {sentence}" for sentence in avoid or [])
    avoid_line = (
        f"""
Already written for this learner, in this same session. Write none of these
again, and no near-variations on them -- a different subject, a different
situation, a different shape of sentence:
{written}
"""
        if written
        else ""
    )
    return f"""Target language: {target_lang}
Source language: {source_lang}

The vocabulary this learner knows, and the only content words you may use:
{known}
{focus_line}{avoid_line}
Write {count} sentences."""
