# Build a fuzzy English IME for Windows using Rime / Weasel

I want you to build a usable prototype of a Windows English input method based on Rime/Weasel.

This is not merely autocomplete and not merely a spell checker. The intended interaction model is closer to a Chinese IME:

> I type an approximate representation of the English word I intend, and the IME presents ranked candidate words. I choose the intended candidate.

I type quickly and often make spelling mistakes, especially adjacent transpositions, omitted letters, extra letters, and similar errors. I also want an aggressively abbreviated input mode where I can type mostly or only the consonants of a word and still recover the full word.

The long-term goal is that I should not need to care very much about exact English spelling while typing.

## Target experience

Examples of the intended behaviour:

```text
mathe
→ mathematics
→ mathematical
→ mathematician
...

recommnedation
→ recommendation

recommned
→ recommend
→ recommended
→ recommending
...

recieve
→ receive

teh
→ the

mthmtcs
→ mathematics

rcmmndtn
→ recommendation

strtfctn
→ stratification

dffmrphsm
→ diffeomorphism

brdsm
→ bordism

trngltn
→ triangulation
```

These examples are illustrative, not a hardcoded lookup list.

I want candidate selection rather than silent autocorrection. The software should not automatically replace my text based on a guess.

## Important usability property

This must remain usable as a general English keyboard.

If I type a word that is absent from the dictionary, a filename, variable name, technical term, acronym, identifier, URL fragment, etc., I must still be able to commit exactly what I typed.

Raw input should therefore remain easily accessible, ideally as a candidate or via Enter.

Do not create a system that traps me inside its dictionary.

## Platform

Primary target:

* Windows 11
* Rime / Weasel (小狼毫)

I often work from WSL, so repository development may happen from WSL even though Weasel itself runs on Windows.

Do not assume a particular Rime user-directory path. Detect/document it correctly.

Before implementing, inspect the current Rime/Weasel ecosystem and current APIs rather than relying on old examples. In particular, determine the current status of:

* Weasel
* librime-lua / Lua support
* Rime schema configuration
* custom translators / filters
* user dictionaries and candidate weighting
* existing English schemas such as easy-en / Easy English
* any existing fuzzy-English work that can sensibly be reused

Reuse good existing components where appropriate, but keep this project understandable and independently maintainable.

## Core features

The first genuinely usable version should support four candidate sources.

### 1. Exact word and prefix completion

Normal English typing should work well.

For example:

```text
mathe
```

should be able to suggest words such as:

```text
mathematics
mathematical
mathematician
```

Normal correctly spelled words should rank extremely well.

### 2. Typo-tolerant matching

Support common fast-typing errors including at least:

* adjacent transposition
* deletion
* insertion
* substitution

Adjacent transposition is particularly important:

```text
theorme → theorem
recommned → recommend
```

Use Damerau-Levenshtein or another suitable metric rather than plain Levenshtein if appropriate.

Consider weighted edit costs rather than treating every edit as equally bad. For English fast typing, plausible useful biases include:

* adjacent transposition: cheap
* omitted vowel: relatively cheap
* inserted vowel: relatively cheap
* keyboard-neighbour substitution: potentially cheap
* consonant substitution: more expensive

Do not blindly implement these weights if experimentation suggests a better model; measure candidate quality.

### 3. Consonant-skeleton input

For every dictionary word, derive a consonant representation, initially with a simple rule such as removing `a e i o u`.

Examples:

```text
mathematics      → mthmtcs
recommendation   → rcmmndtn
stratification   → strtfctn
diffeomorphism   → dffmrphsm
bordism          → brdsm
```

Typing the skeleton should produce the corresponding full word as a strong candidate.

The consonant representation need not require an exact skeleton match forever. Ideally a slightly mistyped skeleton should still be recoverable through fuzzy matching.

Treat `y` sensibly and document the choice.

### 4. Ranking

Candidate ranking matters at least as much as candidate generation.

Design a score combining signals such as:

* exact match
* prefix match
* word frequency
* fuzzy edit cost
* consonant-skeleton match quality
* completion length
* user's previous selections / personal frequency, if available

Broad intended priority:

```text
exact intended word
> very plausible completion
> very close typo correction
> strong consonant reconstruction
> increasingly speculative candidates
```

However, do not hardcode this ordering mechanically if a unified score gives better behaviour.

The top few candidates are what matter. Returning hundreds of technically possible matches is not useful.

## Personal vocabulary

The system should be able to learn vocabulary that I actually use.

This includes mathematical and technical words such as:

```text
bordism
cobordism
diffeomorphism
stratification
categorification
comultiplication
Frobenius
triangulation
topology
homotopy
```

Prefer to use Rime's native user-dictionary / learning machinery where it fits cleanly.

I want frequently selected words to rise over time.

Also make it straightforward to supply a custom plain-text vocabulary file later.

Do not hardcode my mathematical vocabulary into the core algorithm. A sample supplemental dictionary is fine.

## Performance

Interactive latency is important.

Do not perform an unrestricted linear fuzzy-distance scan over a huge English dictionary on every keystroke if that causes noticeable latency.

Investigate an appropriate candidate-generation index. Possible approaches include, but are not limited to:

* prefix trie
* SymSpell-style deletion index
* BK-tree
* n-gram index
* consonant-skeleton reverse index
* Rime dictionary mechanisms
* a hybrid of static precomputed indexes and Lua reranking

I care more about a responsive IME than theoretical elegance.

Precomputation is completely acceptable.

A plausible architecture might be:

```text
raw input
   │
   ├── exact / prefix candidates
   ├── typo candidates from compact fuzzy index
   └── consonant-skeleton candidates
           │
           ▼
     unified reranking
           │
           ▼
       Rime candidates
```

This is only a suggestion. Change it if the Rime architecture makes another design cleaner.

## Dictionary

Use a reasonably good frequency-ranked English word list with a licence suitable for this project.

Record:

* source
* licence
* preprocessing
* number of entries

Avoid filling the top candidates with obscure dictionary words.

It may be useful to have separate frequency tiers or corpus frequencies.

Make the dictionary-building process reproducible rather than committing an unexplained generated blob.

## Rime behaviour

Aim for ordinary IME conventions:

* number keys select candidates
* Space selects the first candidate
* Enter can commit raw input
* Escape cancels composition
* paging through candidates works normally

Do not break punctuation or normal Windows keyboard usage unnecessarily.

It should be easy to switch between this schema and my other Rime schemas.

For the first version, lowercase English is sufficient internally, but think through capitalization rather than making future support impossible.

## Architecture preference

Keep the project small and inspectable.

Prefer:

* Rime schema/config for what Rime already does well
* Lua only where dynamic candidate logic is actually needed
* Python or another simple offline script for dictionary/index generation
* generated indexes separated from handwritten source
* automated tests for the matching/ranking core

Avoid modifying/forking Weasel or librime itself unless you can demonstrate that this is genuinely necessary.

I strongly prefer a normal user-level Rime configuration/plugin over maintaining a custom C++ IME fork.

## Development strategy

Work incrementally, but continue through to a runnable prototype rather than stopping after writing a plan.

### Phase 1 — investigate

Read current authoritative documentation/source/examples and inspect existing English Rime schemas.

Write a short `DESIGN.md` summarising:

* how English translation works in current Rime
* where fuzzy candidate generation should live
* what can be delegated to native Rime
* what must be custom
* proposed indexing/ranking strategy
* expected installation flow on Weasel

Do not spend excessive time producing a literature review. The goal is to make good implementation decisions.

### Phase 2 — build a minimal vertical slice

Get one custom schema working in Weasel with:

* ordinary English candidates
* one custom candidate path
* raw input fallback
* normal selection/commit behaviour

Prove that the integration architecture works before making the fuzzy algorithm sophisticated.

### Phase 3 — implement matching

Implement:

* exact
* prefix
* Damerau-style typo recovery
* consonant skeleton lookup
* ranking

Build reproducible indexes if needed.

### Phase 4 — evaluate

Create a small test corpus containing ordinary input, typos and consonant abbreviations.

At minimum test cases along the lines of:

```text
mathe            → mathematics near the top
recommnedation   → recommendation near the top
recieve          → receive near the top
teh              → the near the top
mthmtcs          → mathematics near the top
rcmmndtn         → recommendation near the top
strtfctn         → stratification near the top
dffmrphsm        → diffeomorphism near the top
brdsm            → bordism near the top
trngltn          → triangulation near the top
```

Add negative / ambiguity tests too.

For example, short inputs such as:

```text
frm
```

may legitimately correspond to several words. Ranking should not pretend there is certainty where there is none.

Measure at least roughly:

* top-1 accuracy on the test set
* top-5 recall
* candidate generation latency

The goal is not a publication-quality benchmark. I want enough evidence to tune the implementation rather than choosing weights by intuition alone.

### Phase 5 — installable prototype

Give me an actual installation procedure for Windows Weasel.

Ideally provide a script that installs or symlinks/copies the required files into the detected Rime user directory, followed by redeployment instructions.

Do not overwrite unrelated existing Rime configuration.

## Repository structure

Use something approximately like:

```text
fuzzy-en-rime/
├── README.md
├── DESIGN.md
├── fuzzy_en.schema.yaml
├── fuzzy_en.dict.yaml
├── lua/
│   └── ...
├── scripts/
│   ├── build_dictionary.py
│   ├── build_indexes.py
│   └── install.py
├── data/
│   ├── README.md
│   └── ...
├── tests/
│   └── ...
└── generated/
    └── ...
```

Adapt this if another layout is more natural.

## Engineering requirements

Please:

* keep functions/modules small
* comment non-obvious Rime APIs
* don't hide important logic in enormous YAML regex lists
* don't generate millions of typo spellings if a compact index solves the same problem
* keep generated files reproducible
* add tests before aggressively tuning ranking
* do not modify unrelated files on my system
* do not require administrator privileges unless absolutely unavoidable
* make reasonable implementation decisions yourself instead of stopping to ask me about every detail

When something is uncertain, prototype it and inspect the result.

## Acceptance criteria

I will consider the first prototype successful if all of the following are true:

1. I can install it as a selectable Weasel/Rime schema on Windows.
2. Correctly spelled English words work naturally.
3. Prefix completion works.
4. Common misspellings can produce the intended word among the first few candidates.
5. Adjacent transpositions are handled well.
6. Consonant-only forms such as `mthmtcs` and `rcmmndtn` can recover useful full words.
7. Candidate generation feels interactive rather than laggy.
8. I can always commit my literal raw input.
9. The system can incorporate my own vocabulary.
10. The implementation is sufficiently clean that we can continue iterating on ranking and matching without rewriting the whole project.

## Deliverables

Do not just tell me how one might build it. Build the prototype.

At the end, give me:

1. the working repository
2. `README.md` with installation/use instructions
3. `DESIGN.md` explaining the architecture
4. automated matching/ranking tests
5. a small benchmark/evaluation result
6. the exact files I need to deploy to Weasel
7. a short list of limitations discovered during implementation
8. your recommended next improvements, ordered by expected impact

If some desirable feature turns out not to fit Rime cleanly, explain the concrete technical limitation and implement the strongest practical version rather than abandoning the task.

The product principle throughout is:

> Treat spelling as a noisy encoding of intended English, and use an IME candidate interface to decode the intention.
