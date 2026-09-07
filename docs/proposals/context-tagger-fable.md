# A tagged-context proposal

Received 2026-09-07, written by Fable, and kept verbatim below the line. It is
a design for a left-context feature built on a part-of-speech tagger, a
backward adjunct scan and a bounded score term.

It is filed here rather than acted on wholesale: parts of it are already built,
parts of it were measured in this repository and lost, and its central scoring
decision is one we have a counter-measurement for. See `docs/ALGORITHM.md` §8.1
for what shipped and why, and the assessment notes at the end of this file.

---

## The brief, as received

You are working in the Spellless repository (https://github.com/EricWay1024/spellless),
a fuzzy English input method whose matcher is pure Lua 5.4 with no dependencies.
Read ALGORITHM.md and DESIGN.md in full before writing any code; everything
below assumes their vocabulary (channels, the additive score in §4.8, the trust
rules in §4.9, the case files in tests/cases, bench/tune.lua). Then implement a
left-context feature that reorders candidates using a small amount of English
syntax. The feature is a tie-breaker for the writer, not an oracle: it may move
candidates by a bounded amount, it never removes a candidate, never touches the
literal-input rules, and never overturns strong evidence from the input itself.

The acceptance criterion in one example. Previous word "would", input `rlt`:
"relate" should lead over "related". Same previous word, input `rltd`:
"related" must still lead, because it is an exact skeleton hit and "relate" has
to pay for deleting a typed consonant. Also: previous words "can thus to some
extent", input `gnrlzd`: "generalized" should be favoured over "generalize",
because the modal "can" is still the open expectation despite the adverb and
prepositional phrase in between. And with no readable context, or an unknown
previous word, the output must be byte-for-byte identical to the current
output.

Design, which you should follow unless you find a concrete reason not to, in
which case say so in the PR description rather than silently diverging.

1. **Tag set.** Define about 40 collapsed Penn-style tags in one Lua file. Keep
   the distinctions that separate morphological siblings: VB, VBZ, VBD, VBN,
   VBG, NN, NNS, JJ, RB, plus function classes: DT, MD, IN (preposition), TO
   (infinitive marker), AUX_HAVE, AUX_BE, NOT, WH, CC, CD, PRP, PRP$, COMMA,
   START (sentence start). Each tag is a small integer.

2. **Word to tag distribution.** Each dictionary word gets up to three (tag,
   weight) pairs, packed as bytes into a shipped array indexed by word id,
   built at make time by `data/build_tags.*` alongside the other indexes.
   Source, in priority order: a hand-written table for the closed classes (all
   determiners, modals, prepositions, pronouns, auxiliaries, common adverbs,
   roughly 300 to 500 words, written by you from knowledge of English, no data
   needed); the Universal Dependencies English EWT treebank (CC BY-SA 4.0; note
   the licence in `data/README.md`) for word-level tag counts of everything it
   covers; and a suffix guesser for the rest, implemented as an ordered list of
   (suffix, tag distribution) rules: `-ed` gives VBD/VBN/JJ, `-ing` gives
   VBG/NN, `-ly` gives RB, `-tion -sion -ness -ment -ity` give NN, `-s` gives
   NNS/VBZ, `-al -ous -ive -ic` give JJ, `-er` gives NN/JJ, otherwise NN/VB.
   The literal input candidate and any unknown word are tagged by the suffix
   guesser at query time, so the context term applies to all candidates
   uniformly.

3. **Expectations.** For each expectation-setting class, a distribution over
   the next tag: MD wants VB, AUX_BE, NOT, RB; AUX_HAVE wants VBN, NOT, RB; TO
   wants VB, RB; DT and PRP$ want NN, NNS, JJ, CD; IN wants DT, NN, NNS, VBG,
   PRP; AUX_BE wants VBG, VBN, JJ, DT; RB after JJ-intensifiers ("very",
   "more", "quite") wants JJ, RB; START wants DT, PRP, NN, WH; and the special
   case that the determiner "an" wants a vowel-initial word and "a" a
   consonant-initial one, checked directly against the candidate's first
   letter. Write these by hand first as a Lua table keyed by tag with an
   override table keyed by specific word for the frequent function words
   ("would", "the", "these", "has", "very", "of", "not", "to"). Then, from UD,
   compute a tag-trigram table P(t_i | t_{i-2}, t_{i-1}) quantised to bytes
   (40^3 entries) as the backoff for contexts where no setter is found. Also
   compute the unigram tag prior P(t).

4. **Backward adjunct scan.** The frontend supplies up to 32 characters before
   the caret (see DESIGN.md for how the string arrives; extend the adapter in
   `rime/lua/spellless.lua` and do not change the matcher's interface beyond
   adding an optional context argument). Tokenise it into words; discard the
   whole context unless the string ends in a complete word followed by exactly
   one space, or in sentence punctuation followed by a space (then the context
   is START). Walk right to left with a small automaton whose transitions
   consume adjuncts: adverbs; NOT; floated quantifiers ("all", "both", "each");
   a prepositional phrase, recognised right to left as noun or pronoun,
   optional adjectives, optional determiner, then a word tagged IN, where "to"
   followed by a determiner or noun counts as IN and otherwise as TO; a
   parenthetical between two commas. Stop at the first word whose tag set
   contains an expectation-setting class and report (setter word, setter tag,
   tokens skipped, confidence). Confidence starts at 1, multiplied by gamma^k
   for k tokens skipped with gamma = 0.7, and halved whenever a skipped token's
   classification was ambiguous. If the scan reaches the window edge or a
   non-adjunct non-setter, report no setter and fall back to the trigram over
   the last two tags with confidence 0.5.

5. **Score term.** For candidate w with tag distribution P(t | w) and the
   context's next-tag distribution P(t | c) from step 3 or 4, add to the score

       lambda * conf * clip( log( sum_t P(t|w)P(t|c) / sum_t P(t|w)P(t) ), -B, +B )

   with initial lambda = 2 points per nat (consistent with w_f/R as discussed
   in ALGORITHM.md §8.2) and B = 4 nats, so the term is bounded by eight
   points, which is below the roughly fourteen points that one deleted typed
   consonant costs under the elastic profile. Apply the term in the ranking
   function alongside the other terms, after all channels have generated, never
   during generation, and never to the decision of whether the literal leads
   (§4.9), which must read the score before this term is added. Add the term as
   its own line to the `--debug` output of `bench/try.lua`, in the form
   `context: after 'can' (modal, 3 skipped, conf 0.34): base verb expected,
   +3.1`, so a user can see why a candidate moved.

6. **Tests.** Extend the case file format with an optional fourth column for
   context (a string of preceding text). Add `tests/cases/context.tsv` with at
   least 40 hand-written cases covering: the four examples above; a determiner
   before a noun/adjective sibling pair; "have" before a participle with "not"
   and an adverb in between; "to" before a verb with a split-infinitive adverb;
   "a" and "an" against candidate first letters; a context that ends mid-word
   (must be ignored); a context with an unknown previous word (must be
   ignored); a candidate that is the literal input and gets the suffix-guesser
   tag; and a strong-evidence case where the context points the wrong way and
   must lose. Every existing case must pass unchanged with empty context. Add
   unit tests for the suffix guesser and for the backward scan on at least 20
   sentences, asserting the setter it finds. Add a property test that the
   context term is always within [-lambda*B, +lambda*B] and is exactly zero
   when the context is empty.

7. **Held-out evaluation.** Write `bench/context_eval.lua` that takes UD EWT
   sentences not used to build the tables (split by sentence id), picks content
   words of at least six letters, abbreviates each with the existing generator
   (skeleton and syllabic modes), uses the preceding tokens as context, and
   reports top-1 and top-5 with the context term off and on, broken down by
   whether a setter was found and by number of skipped tokens. Report those
   numbers in the PR. Then tune lambda, B and gamma with `bench/tune.lua` on
   the case files and check they do not hurt the held-out number; if tuning
   wants B above 6, stop and say so rather than accept it.

8. **Latency and size.** The added cost must be under 0.3 ms per keystroke on
   the bench in ALGORITHM.md §5.3, and the shipped tables must add under
   300 kB. The scan runs once per query, not per candidate; per-candidate work
   is a few table lookups and one log. Keep everything in pure Lua 5.4 with no
   compiled extension.

9. **Documentation.** Update ALGORITHM.md: replace §8.1 with a description of
   what was built, its held-out numbers, and what it deliberately does not
   attempt (long-distance agreement not shaped like an adjunct, anything
   outside the window, noun-versus-noun ambiguities). Add the data source and
   licence to `data/README.md` and the new make step to the Makefile so `make`,
   `make test` and `make bench` reproduce everything.

Work in that order, committing after each step with tests passing. Do not
refactor unrelated code. If any instruction conflicts with the invariants in
ALGORITHM.md §8.0, the invariants win and you should flag the conflict.
