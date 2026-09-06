We want to add one new matching idea to Spellless:

**syllabic fuzzy shorthand matching**

The intuition is that a user may mentally pronounce a word syllable by syllable and type only 1–2 salient letter cues per syllable, without learning any explicit shorthand system.

Example:

`stratification`
→ roughly `strat / i / fi / ca / tion`
→ user might naturally type something like:

`satfcatn`

Other plausible inputs could be:

`stifctn`
`stfcatn`
`stfctn`

There should be **no new input mode and no shorthand codebook to learn**. This should simply be another way the existing matcher can interpret a query.

## Goal

Prototype a new matcher/scoring component that gives unusually low cost to deletions that preserve roughly one or two useful cues per syllable.

Conceptually, for a candidate word split into syllables

`w = s1 s2 ... sn`

allow the query to be segmented as

`x = x1 x2 ... xn`

where each `xi` is usually 1–2 characters, and score

`score(w, x) = min over segmentations sum_i cost(si, xi)`.

Do not take this mathematical formulation too literally if a simpler implementation works better.

The important behaviour is:

* `satfcatn` should score well for `stratification`;
* users should be allowed to choose different cues for the same syllable;
* there must be no strict rule such as "`tion` always maps to `tn`";
* normal spelling, typos, consonant skeleton input, prefixes, etc. must continue to work exactly as before;
* this is just an additional matching signal/channel.

## Suggested approach

1. Inspect the current Spellless matching architecture and existing evaluation setup.
2. Find the smallest clean way to introduce a syllable-aware score.
3. Prefer an experimental implementation over a large refactor.
4. Use an existing pronunciation/syllabification source if convenient, but avoid adding a heavy runtime dependency. Precomputation is fine.
5. Combine this score with the existing matcher rather than replacing it. For example, the final candidate score might take the best or a calibrated combination of:

   * ordinary fuzzy/edit matching;
   * consonant-skeleton matching;
   * syllabic shorthand matching.
6. Keep runtime performance appropriate for interactive typing.

## Important design principle

Do **not** design an "English Shuangpin" layout or require the user to learn mappings.

The intended user instruction should be approximately:

> Think of the word syllable by syllable and type one or two letters that feel representative of each syllable. The decoder should do the rest.

The system should adapt to natural lossy input, not train the user to obey a codebook.

## Evaluation

Before integrating deeply, make this measurable.

Create a small synthetic or hand-curated benchmark of syllabic shorthand queries, including examples such as:

* `satfcatn` → `stratification`
* variants of the same word using different cues per syllable
* long technical words such as `mathematics`, `diffeomorphism`, `homotopy`, `categorification`, etc.

Compare:

* current matcher;
* current matcher + syllabic matcher.

Report at least:

* top-1 accuracy;
* top-5 accuracy;
* latency impact;
* examples where the new matcher helps;
* examples where it introduces bad candidates or regressions.

If the existing Spellless matcher already handles most of these cases, quantify that first. It is completely acceptable if the conclusion is that only a very small scoring tweak is needed.

Please implement the smallest useful prototype, run the evaluation, and document what you changed and what the results suggest.
