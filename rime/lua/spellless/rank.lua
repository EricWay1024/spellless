-- Turning candidates from several sources into one ordered list.
--
-- Everything is a single additive score rather than a fixed source ordering,
-- so a very common word reached by a cheap typo can legitimately overtake a
-- rare exact prefix completion.  The per-source base values in config.lua only
-- express the *broad* priority; frequency, edit cost, how much text the
-- completion adds and the user's own history do the fine ordering.

local skeleton = require("spellless.skeleton")
local wordclass = require("spellless.wordclass")

local M = {}

local BASE_KEY = {
  exact    = "base_exact",
  prefix   = "base_prefix",
  typo     = "base_typo",
  skeleton = "base_skeleton",
  cue      = "base_cue",
}

--- How much longer the candidate is than what was typed, normalised to [0,1].
--- Only completions are penalised; a shorter word already paid through cost.
local function extra_penalty(extra)
  if extra <= 0 then return 0 end
  if extra > 10 then return 1 end
  return extra / 10
end

--- Score one candidate.  `ctx` carries the per-query values that do not depend
--- on the candidate: the abbreviation-likeness of the input and the lookups
--- for corpus/personal frequency.
function M.score(item, cfg, ctx)
  local base = cfg[BASE_KEY[item.source]]
  if not base then return -math.huge end
  -- Familiarity is evidence about the *word*; cost is evidence about the
  -- *reading*.  Multiplying one by the other is the mistake: that you write
  -- "instead" sixteen times a day is no reason at all to think `immsn` was it.
  --
  -- It was, though.  `immsn` put the literal first and `immersion` third,
  -- because "instead" came back through the skeleton channel at cost 1.55 --
  -- a stretch by any measure -- and eighteen points of familiarity covered the
  -- 16.5 the extra cost had taken off, winning by 0.1.  Then, the leader being
  -- that loose, nothing was trustworthy and the literal was promoted over a
  -- perfectly good cost-0.52 reading sitting right behind it.
  --
  -- So familiarity stops where trust does.  `confidence_cost` already means
  -- "a reading this loose is not to be relied on"; this says that knowing the
  -- word does not make it any more reliable.  Below the threshold nothing
  -- changes, which is every ordinary correction.
  -- Familiarity is evidence about the *word*; cost is evidence about the
  -- *reading*.  That you write "instead" sixteen times a day is a reason to
  -- prefer it among readings that explain the input equally well, and no
  -- reason at all to accept a reading that explains it much worse.
  --
  -- It was accepted.  `immsn` put the literal first and `immersion` third,
  -- because "instead" came back at cost 1.55 -- and eighteen points of
  -- familiarity covered the 16.5 the extra cost had taken off, winning by 0.1
  -- over a cost-0.52 reading.  The leader being that loose, nothing was
  -- trustworthy and the literal was promoted over the good answer behind it.
  --
  -- So the bonus is withdrawn from a reading that is *much worse than the best
  -- one on offer* -- not from a poor reading as such.  The absolute cost is
  -- the wrong test and a sweep over a real store proved it: a flat threshold
  -- lost nine recorded corrections, `buracitc` -> bureaucratic among them,
  -- which are exactly the hard repairs familiarity is there to rescue.  Those
  -- are the best reading available; "instead" was not.
  local excess = item.cost - (ctx.best_cost or 0)
  local familiarity = 0
  if excess <= cfg.user_cost_margin then
    familiarity = cfg.user_weight * ctx.user(item)
  end
  item.familiarity = familiarity
  local s = base
      + cfg.freq_weight * ctx.freq(item)
      + familiarity
      - cfg.cost_weight * item.cost
      - cfg.extra_weight * extra_penalty(item.extra)
  -- No corpus id means the dictionary does not have this word at all -- but a
  -- split is made entirely of words that are in it.
  if not item.id and item.source ~= "split" then
    s = s - cfg.unknown_word_penalty
  end
  if item.has_form and item.source == "exact" then
    s = s + cfg.form_bonus
  end
  -- Signed: a consonant-only input is strong evidence for the abbreviation
  -- reading, a vowel-rich one is evidence against it.  Both sources are
  -- readings of the same guess -- that this is shorthand -- so both answer to
  -- the same evidence; leaving cues out of it meant "tnk" ranked the exact
  -- skeleton of a rare word above a common word one dropped letter away.
  --
  -- Two knobs rather than one because they are two channels and the tuner
  -- should be able to separate them.  They agree today; what actually settled
  -- "mathe" -- where the cue readings (Matthew, matches) once sat above half
  -- the completions of the word being spelled out -- was raising base_cue, not
  -- steepening this.
  if item.source == "skeleton" then
    s = s + cfg.skeleton_vowel_bonus * (2 * ctx.abbreviation_likeness - 1)
  elseif item.source == "cue" then
    s = s + cfg.cue_vowel_bonus * (2 * ctx.abbreviation_likeness - 1)
  end
  return s
end

--- Nudge near-ties towards the class the previous word predicts.
---
--- Applied after the per-word deduplication and before the sort, on the
--- candidates only, so it can settle "regulator" against "regulatory" without
--- being able to overturn anything the input actually decided.  Three
--- properties are load-bearing:
---
---   * it is a log-ratio, not a log-probability, so it is zero-centred: an
---     unreadable previous word and an unclassifiable candidate both contribute
---     exactly nothing, and adding the term can only reorder candidates whose
---     classes differ.  A log P term would instead push every classifiable
---     candidate down relative to every unclassifiable one, which is a bias
---     about the class function rather than about the language;
---   * it is scaled in points per nat, the same units as the frequency term,
---     so it enters the additive score at a rate that means something;
---   * it only reaches candidates within `context_margin` of the leader, so an
---     exact match -- which leads its sibling by 20 points or more once
---     form_bonus is in -- is out of reach whatever the previous word was.
---
--- `ctx.previous_class` is nil unless the engine both has the flag on and could
--- read the previous word, and then this whole function is one comparison.
function M.apply_context(out, cfg, ctx)
  local previous = ctx.previous_class
  if not previous then return end
  local top = -math.huge
  for i = 1, #out do
    if out[i].score > top then top = out[i].score end
  end
  local floor, weight = top - cfg.context_margin, cfg.context_weight
  for i = 1, #out do
    local item = out[i]
    if item.score >= floor then
      local bonus = weight * wordclass.pmi(previous, wordclass.of(item.word))
      if bonus ~= 0 then
        item.score = item.score + bonus
        item.context = bonus
      end
    end
  end
end

--- Familiarity may not overturn an exact match.
---
--- The personal store is a handful of counts from whatever happened to be
--- typed lately -- including the mistakes committed while something was
--- broken -- and the dictionary is measured English.  So history nudges, it
--- does not decide, and the one place that has always had to be true is
--- against a word you actually typed: "sth" must mean "something" however many
--- hundreds of times "the" has been committed.
---
--- That guarantee used to rest on base_exact standing far enough above every
--- other base to outrun `user_weight` at saturation.  It is stated here
--- instead, which is both the honest place for it and what lets base_exact be
--- set on the evidence it is actually about -- how much a word you typed is
--- worth against a commoner word it completes -- rather than on how large a
--- personal bonus it has to survive.
---
--- Only the bonus is held back, never the frequency: a rival that beats the
--- exact match on measured English alone still wins, which is exactly the case
--- this is not about.
function M.hold_exact(out)
  local ceiling
  for i = 1, #out do
    local item = out[i]
    if item.source == "exact" and (not ceiling or item.score > ceiling) then
      ceiling = item.score
    end
  end
  if not ceiling then return end
  for i = 1, #out do
    local item = out[i]
    if item.source ~= "exact" and item.score > ceiling
       and (item.score - (item.familiarity or 0)) <= ceiling then
      item.held = item.score - ceiling
      item.score = ceiling - 1e-9
    end
  end
end

--- After a modal, sink the -ed readings to the back of the first page.
---
--- A reordering and not a score: the two are not the same thing, and the
--- difference showed up the first time this was tried.  Eight points off
--- `related` moved it from first to *fourteenth*, because the field around a
--- three-letter skeleton is dense enough that eight points spans a dozen
--- words.  That is removal wearing the clothes of a demotion.
---
--- A stable partition of the first page says exactly what the rule knows and
--- nothing more.  Grammar knows which readings are wrong here; it does not
--- know how much better `result` is than `reality`, so it is not allowed an
--- opinion about that, and the relative order on each side of the partition is
--- the ranker's throughout.  The bound is the point: a demoted word cannot
--- leave the page it was on, so the worst case is one glance rather than one
--- lost word.
---
--- Applied after the sort, because it is about positions and not about scores.
function M.defer_inflections(out, cfg, ctx)
  if not ctx.prefer_bare then return end
  local window = math.min(cfg.bare_verb_window, #out)
  if window < 2 then return end
  local keep, sunk = {}, {}
  for i = 1, window do
    local item = out[i]
    if ctx.past_inflection(item) then sunk[#sunk + 1] = item
    else keep[#keep + 1] = item end
  end
  if #sunk == 0 or #keep == 0 then return end
  for i = 1, #keep do out[i] = keep[i] end
  for i = 1, #sunk do out[#keep + i] = sunk[i] end
end

--- Rank `items`, keeping the best-scoring entry per word.
--- Returns a list ordered by descending score.
function M.rank(items, query, cfg, ctx)
  ctx.abbreviation_likeness = 1 - skeleton.vowel_ratio(query)
  -- How well the best reading on offer explains the input, which is what every
  -- other reading's cost is judged against; see the familiarity note above.
  local best_cost = math.huge
  for i = 1, #items do
    if items[i].cost < best_cost then best_cost = items[i].cost end
  end
  ctx.best_cost = best_cost < math.huge and best_cost or 0

  local best, order, count = {}, {}, 0
  for i = 1, #items do
    local item = items[i]
    item.score = M.score(item, cfg, ctx)
    local key = ctx.text(item)
    local prev = best[key]
    if not prev then
      best[key] = item
      count = count + 1
      order[count] = key
    elseif item.score > prev.score then
      best[key] = item
    end
  end

  local out = {}
  for i = 1, count do out[i] = best[order[i]] end
  M.hold_exact(out)
  M.apply_context(out, cfg, ctx)
  -- Ties are broken by corpus rank so the order is stable and reproducible.
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return ctx.tiebreak(a) < ctx.tiebreak(b)
  end)
  -- Whether the matcher believes its own answer is a question about the input,
  -- and it must not acquire an opinion about the word before it.  Engine's
  -- trust test reads the leader, so it is handed the one the *ranking* chose
  -- and not the one the reorder left in front (ALGORITHM.md 8.0, invariant 1).
  --
  -- Not hypothetical: `allsg` reads as `alleged`, comfortably trusted, and
  -- demoting it after a modal put a below-floor candidate in first place and
  -- made the literal `allsg` lead.  One skeleton in 8,646 -- which is what a
  -- rare violation of an invariant looks like from the outside.
  out.leader = out[1]
  M.defer_inflections(out, cfg, ctx)
  return out
end

return M
