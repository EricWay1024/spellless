# Decoding lossy input: a systematic account

**The Spellless matching algorithm, stated as a decision problem over a family of noisy channels.** Prose version of the same material: `docs/ALGORITHM.md`, which also carries the evaluation and the open problems. Every constant here is from the current tree; `make test` and `lua bench/evaluate.lua` are what keep them honest.

---

## 1. Notation

Let $\Sigma = \{\texttt{a},\dots,\texttt{z},\texttt{'}\}$ and let $V = \{\texttt{a},\texttt{e},\texttt{i},\texttt{o},\texttt{u}\} \subset \Sigma$ be the vowels.

Let $D \subset \Sigma^{*}$ be the dictionary, $N = |D| = 83{,}364$, equipped with a normalised log-frequency
$$f : D \to [0,1], \qquad f(w) = \frac{\log \nu(w) - \log \nu_{\min}}{\log \nu_{\max} - \log \nu_{\min}},$$
where $\nu$ is a corpus count. The dynamic range $\log \nu_{\max} - \log \nu_{\min}$ is $14.41$ nats; this constant sets the exchange rate in §5.

Write $q \in \Sigma^{*}$ for the query — what the user typed — with $n = |q|$, and $m = |w|$ for a candidate.

Three relations on $\Sigma^{*}$ are used throughout.

- **Prefix.** $u \sqsubseteq v$ iff $v = u\,x$ for some $x \in \Sigma^{*}$.
- **Subsequence.** $u \preceq v$ iff there exist $1 \le j_{1} < \cdots < j_{|u|} \le |v|$ with $u_{i} = v_{j_{i}}$ for all $i$.
- **Skeleton.** $\sigma : \Sigma^{*} \to \Sigma^{*}$ deletes every character in $V$ except the first character of the string, which is always kept. (Note $\texttt{y} \notin V$, so $\sigma$ keeps it: $\sigma(\texttt{system}) = \texttt{systm}$, $\sigma(\texttt{about}) = \texttt{abt}$.)

Note $u \sqsubseteq v \Rightarrow u \preceq v$ and $\sigma(v) \preceq v$.

## 2. The problem

**Model.** The user selects an intended word $w \in D$ and transmits it through a lossy encoder, which emits $q$. The system observes $q$ and must invert:

$$P(w \mid q) \;\propto\; \underbrace{P(q \mid w)}_{\text{channel}} \cdot \underbrace{P(w)}_{\text{prior}}.$$

**Task.** Return an ordered list $C = (c_{1},\dots,c_{k})$, $k \le 20$, maximising $P(\text{intended} = c_{1})$ and, secondarily, $P(\text{intended} \in \{c_{1},\dots,c_{5}\})$, subject to a hard constraint:

$$q \in C \quad \text{always.} \tag{L}$$

Constraint (L) is not probabilistic and is discussed in §7. It exists because silently converting a deliberate token (`kubectl`, `argmax`, a surname) into an English word is the one failure that corrupts a document unobserved.

**Budget.** The whole computation runs on every keystroke: $2.5$ ms mean, under $10$ ms at the 95th percentile, in single-threaded interpreted Lua. Evaluating $P(q \mid w)$ for all $N$ words costs $165$ ms, so at most $1/70$ of the dictionary may be examined.

## 3. Channels

> **Definition 3.1.** A *channel* is a triple $\mathcal{C} = (R, \kappa, \Gamma)$ where
> - $R \subseteq \Sigma^{*} \times D$ is a **relation**: the pairs $(q,w)$ this channel can explain at all;
> - $\kappa : R \to [0,\infty)$ is a **cost**, read as $-\log P(q \mid w)$ up to an additive constant;
> - $\Gamma : \Sigma^{*} \to 2^{D}$ is a **generator** with $\Gamma(q) \subseteq \{ w : (q,w) \in R \}$, computable within the budget of §2.

The generator is the part that makes this an algorithm rather than a model. $\Gamma$ is *not* required to be complete: it may miss pairs in $R$, and does. §6 is about what that costs.

> **Definition 3.2 (weighted OSA).** For a price vector $\theta$ assigning a cost to each edit operation, let $d_{\theta}(u,v)$ be the minimum total price of a sequence of insertions, deletions, substitutions and non-overlapping adjacent transpositions taking $u$ to $v$. Let
> $$d^{\mathrm{pre}}_{\theta}(u,v) \;=\; \min_{v' \sqsubseteq v} d_{\theta}(u,v')$$
> be the corresponding *prefix distance*, obtained as the minimum over the final row of the same dynamic program.

Three price vectors are used. $\theta_{\mathrm{typo}}$ is the table of §4.1. $\theta_{\mathrm{skel}}$ is $\theta_{\mathrm{typo}}$ with the vowel discounts removed, both arguments being vowel-free. $\theta_{\mathrm{el}}$ (*elastic*) is deliberately asymmetric: inserting a vowel the user omitted costs $0.10$, deleting a vowel the user actually typed costs $0.90$.

> **Remark 3.3.** The asymmetry of $\theta_{\mathrm{el}}$ is load-bearing. Under a symmetric price, $\sigma(\texttt{mathe}) = \texttt{mth}$ matches `mouth` exactly as cheaply as `mthmtcs` matches `mathematics`. Characters the user did type are evidence; deleting them must be expensive.

## 4. The five channels

### 4.1 $\mathcal{C}_{1}$, exact — *nothing happened*

$$R_{1} = \{(q,w) : q = w\}, \qquad \kappa_{1} = 0.$$

$\Gamma_{1}$ is a binary search of the alphabetical permutation of $D$.

### 4.2 $\mathcal{C}_{2}$, prefix — *you stopped early*

$$R_{2} = \{(q,w) : q \sqsubseteq w\}, \qquad \kappa_{2} = 0.$$

$\Gamma_{2}$ is the same binary search, keeping the $12$ most frequent completions. The cost is zero, but the ranking charges a separate penalty $w_{e}\,\rho(m - n)$ with $\rho(x) = \min(x/10, 1)$: a completion is not *repaired*, it is merely *unfinished*, and the further it is from what was typed the weaker the evidence.

### 4.3 $\mathcal{C}_{3}$, typo — *letters slipped*

$$R_{3} = \{(q,w) : d_{\theta_{\mathrm{typo}}}(q,w) \le B_{3}\}, \qquad \kappa_{3} = d_{\theta_{\mathrm{typo}}}, \qquad B_{3} = 1.35.$$

The price vector $\theta_{\mathrm{typo}}$:

| edit | price | example |
| --- | --- | --- |
| dropped apostrophe | $0.15$ | `dont`, `its`, `id` |
| adjacent transposition | $0.45$ | `teh`, `recommned` |
| miscounted double | $0.55$ | `commited`, `accomodate` |
| dropped or doubled vowel | $0.70$ | `seperate`, `definately` |
| neighbouring key | $0.70$ | `nirth` $\to$ `north` |
| any other substitution or indel | $1.00$ | |

$\Gamma_{3}$ is a bounded scan: buckets of words with $\bigl||w| - |q|\bigr| \le 2$ whose first character equals $q_{1}$ or $q_{2}$, filtered by a $26$-bit letter-mask test before any distance is computed, capped at $1200$ evaluations.

> **Remark 4.1.** The prices are the entire content of $\mathcal{C}_{3}$, and they are not uniform because English fast-typing noise is not. Miscounted doubling needed its own row: `commited` reaches `commuted` for $0.70$ as a neighbouring key, so at a uniform $1.00$ the wrong word beat `committed`.

### 4.4 $\mathcal{C}_{4}$, skeleton — *you dropped the vowels*

$$R_{4} = \bigl\{(q,w) : d_{\theta_{\mathrm{skel}}}^{\mathrm{pre}}\bigl(\sigma(q), \sigma(w)\bigr) \le B_{4}\bigr\}, \qquad \kappa_{4} = d^{\mathrm{pre}}_{\theta_{\mathrm{el}}}(q, w), \qquad B_{4} = 1.30.$$

$\Gamma_{4}$ uses an index keyed on $\sigma(w)$, in three legs: the exact skeleton class, bounded skeleton *completions*, and a fuzzy scan over skeleton lengths $\pm 1$. The index is additionally probed with each of the five vowels prepended to $q$, which is how `nvrnmnt` reaches `environment`.

> **Remark 4.2 (generate on one cost, price on another).** $\mathcal{C}_{4}$ is the only channel whose $\Gamma$ and $\kappa$ disagree: candidates are *found* by comparing skeletons and *scored* by an elastic alignment against the original $q$. Generation is deliberately loose and ranking supplies the precision. $\sigma(\texttt{mathe}) = \sigma(\texttt{mouth})$, so `mouth` is generated for `mathe`; it costs $1.60$ elastic, which is $25.6$ points, which places it below twenty better readings.

### 4.5 $\mathcal{C}_{5}$, syllable cue — *you dropped whatever felt unimportant*

$$R_{5} = \{(q,w) : q \preceq w\} \;\cup\; \{(q,w) : q' \preceq w \text{ for some } q' \text{ differing from } q \text{ in one position}\}.$$

This is the only channel with a genuine generative model. Partition $\Sigma$-positions of $w$ into three classes by the map
$$c(j) = \begin{cases} \mathsf{vow} & w_{j} \in V,\\[2pt] \mathsf{clus} & w_{j} \notin V \text{ and } w_{j\pm1} \notin V \text{ for some sign},\\[2pt] \mathsf{ons} & w_{j} \notin V \text{ and } w_{j-1}, w_{j+1} \in V, \end{cases}$$
and give each class a **keep probability** $p_{c}$. Fix a witnessing alignment; let $K \subseteq \{1,\dots,m\}$ be the positions of $w$ the user kept and $D_{w} = \{1,\dots,m\} \setminus K$ those they dropped. Then

$$\kappa_{5}(q,w) \;=\; \frac{1}{s}\left[\; -\sum_{j \in K} \log p_{c(j)} \;-\; \sum_{j \in D_{w}} \log\bigl(1 - p_{c(j)}\bigr)\;\right], \qquad B_{5} = 12 \text{ nats},$$

minimised over alignments by a dynamic program, with $s = 9$ (`cue_cost_scale`) converting nats to the ranker's units.

| class | meaning | $p_{c}$ |
| --- | --- | --- |
| $\mathsf{vow}$ | a vowel | $0.32$ |
| $\mathsf{clus}$ | a consonant beside another consonant | $0.76$ |
| $\mathsf{ons}$ | a consonant between two vowels — a syllable onset | $0.86$ |

> **Proposition 4.3.** $\kappa_{5}$ is a normalised log-likelihood: it scores every position of $w$, kept or dropped, so it does not systematically favour long words the way a per-skip penalty does.

> **Remark 4.4.** The $p_{c}$ are **counted, not fitted**. An alignment determines $K$ and $D_{w}$, so class-wise keep rates are closed-form counts; hard EM over the $357$ known (shorthand, word) pairs converges in two iterations to $(0.39, 0.68, 0.89)$, and subsequent coordinate descent moves them to the shipped values for a gain of $0.002$. This is the only place in the system where a parameter was measured rather than chosen, and it is exactly where held-out optimism vanished (§6).

> **Remark 4.5.** Both prices in $\kappa_{5}$ are strictly positive, so the running row minimum of the dynamic program is non-decreasing and early abort at $B_{5}$ is sound.

$\Gamma_{5}$ cannot use an index — a subsequence has no prefix to search on. It scans first-letter buckets under three filters: the letter-mask test $m_{q} \wedge \neg m_{w} = 0$ (every letter typed must occur in $w$), a leftmost-greedy subsequence check, and a length ceiling $m \le \min(n + 12,\, 3n)$. It is skipped entirely when $q \in D$, since shorthand is what one writes *instead of* a word — which is also what makes the common case free.

## 5. The decision rule

Candidates from all channels are pooled and scored by one function. For $w$ generated by channel $i$:

$$\operatorname{score}(w, i) \;=\; \beta_{i} \;+\; w_{f} f(w) \;+\; w_{u} u(w) \;-\; w_{c}\,\kappa_{i}(q,w) \;-\; w_{e}\,\rho\bigl(m - n\bigr) \;-\; P_{\mathrm{unk}}\mathbb{1}[w \notin D] \;+\; B_{\mathrm{form}}\mathbb{1}[\,\cdot\,] \;+\; V_{i}\bigl(2\alpha(q) - 1\bigr),$$

where $u(w) = \min\!\bigl(\log(1 + \mathrm{count}(w)) / \log 13,\; 1\bigr)$ is normalised personal history and $\alpha(q) = 1 - (\text{vowel ratio of } q)$ measures how consonantal the input looks. The final term is signed and applies only for $i \in \{4,5\}$: consonant-heavy input is evidence *for* an abbreviation reading, vowel-rich input evidence *against* it.

The output is this list sorted, with $q$ inserted to satisfy (L).

> **Proposition 5.1.** $\operatorname{score}$ is, up to an additive constant and a positive scale, the log-posterior of §2 with $\beta_{i} = \log P(\text{channel} = i)$, $w_{f} f(w) = \log P(w)$ and $w_{c}\kappa_{i} = -\log P(q \mid w, i)$, maximised rather than marginalised over $i$.

Shipped constants:

$$\beta_{1} = 84,\quad \beta_{2} = 74,\quad \beta_{3} = 75,\quad \beta_{4} = 62,\quad \beta_{5} = 70;$$
$$w_{f} = 34,\quad w_{u} = 18,\quad w_{c} = 16,\quad w_{e} = 8,\quad P_{\mathrm{unk}} = 25,\quad B_{\mathrm{form}} = 70,\quad V_{4} = V_{5} = 10.$$

> **Proposition 5.2 (units).** Since $f$ spans $14.41$ nats over $[0,1]$, $w_{f}$ prices frequency at $34/14.41 = 2.36$ points per nat, and one unit of edit cost at $w_{c}/2.36 = 6.78$ nats — a ratio of about $880 : 1$. A repair must additionally cross $\beta_{1} - \beta_{3} = 9$ points, or $3.8$ nats.

> **Proposition 5.3 (gauge freedom).** $\operatorname{score}$ is defined only up to a positive scale: replacing every constant above by $\lambda \cdot (\cdot)$ for $\lambda > 0$ leaves the induced ordering unchanged, and the evaluation identical to six decimal places. The sole exception is the threshold `confidence_floor` of §7, the one place a score is compared with a constant rather than with another score. Together with a dead fifteenth constant since removed, this is why the nominal parameter count of $15$ is really $13$.

## 6. Structure of the family

> **Proposition 6.1 (nesting).** Ignoring budgets, the relations satisfy
> $$R_{1} \subset R_{2} \subset R_{5}, \qquad R_{1} \subset R_{4} \subset R_{5}, \qquad R_{1} \subset R_{3},$$
> and $R_{3} \not\subseteq R_{5}$, $R_{5} \not\subseteq R_{3}$.

*Proof sketch.* $q = w \Rightarrow q \sqsubseteq w \Rightarrow q \preceq w$ gives the first chain. For the second, $\sigma(w) \preceq w$ and $\mathcal{C}_{4}$ accepts $q$ with $\sigma(q)$ close to $\sigma(w)$, of which $q = \sigma(w)$ is the special case obtained by deleting only vowels; $R_{5}$ deletes arbitrary characters. For the last two, $\mathcal{C}_{3}$ permits substitutions, insertions and transpositions, which introduce characters not in $w$ and so fall outside $\preceq$; conversely $\mathcal{C}_{5}$ admits deletions of unbounded total price under $\theta_{\mathrm{typo}}$ — `satfcatn` $\to$ `stratification` costs $4.80$ there and $0.86$ here. $\square$

> **Corollary 6.2.** The five channels are not a partition of the noise space. A word is routinely generated by three of them at three different prices, and the ranking of §5 selects. The redundancy is deliberate.

> **Remark 6.3 (why five, then).** The decomposition is not a claim about English. Modulo $\mathcal{C}_{3}$, all of them are deletion channels, and $\mathcal{C}_{5}$ subsumes the rest; a single generative model with one counted parameter set would be more honest and is what `docs/ALGORITHM.md` §8.3 proposes. The obstruction is entirely $\Gamma$: no single index enumerates under the general model inside the budget of §2. **The five channels are five indexes wearing five cost functions, not five theories of noise.**

## 7. Where this is not a probability model

Four places, in decreasing order of how much they matter.

- **Incommensurable units.** $\kappa_{5}$ is in nats; $\kappa_{3}$ and $\kappa_{4}$ are in arbitrary edit prices. They are reconciled by the hand-set $s = 9$, which has no probabilistic meaning, and the normalised model does *not* beat the hand-tuned prices without it. Held out, $s$ trades $\mathcal{C}_{4}$ against $\mathcal{C}_{5}$ at about two to one with the aggregate flat — so the data does not choose $s$, and it is a statement about who is typing.
- **The priors are fitted, not counted.** The $\beta_{i}$ come from coordinate descent on constructed cases (§5.4 of the long version), maximising a macro average of $2\cdot\text{top-1} + \text{top-5} + \text{in-rank}$; $84\%$ of that gain survives on fresh seeds. Three constants — $w_{u}$, $P_{\mathrm{unk}}$, $B_{\mathrm{form}}$ — encode a principle rather than a tuning result, and $\beta_{1}$ was set by hand.
- **$\Gamma$ is incomplete, so this is a max over what was found**, not a marginalisation over $R$. A word in $R_{i}$ that $\Gamma_{i}$ did not enumerate has posterior zero by construction.
- **Constraint (L) is not a probability.** The literal $q$ occupies a fixed slot, and leads whenever nothing found is *trustworthy* — a predicate combining $\kappa \le 1.50$, $\operatorname{score} \ge 62$ (`confidence_floor`), and length and capitalisation tests. This is a hard constraint bolted to the outside of the inference, and it is the reason Proposition 5.3's gauge freedom is only *almost* free.
