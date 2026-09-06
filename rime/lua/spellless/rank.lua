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
  split    = "base_split",
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
  local s = base
      + cfg.freq_weight * ctx.freq(item)
      + cfg.user_weight * ctx.user(item)
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

--- Rank `items`, keeping the best-scoring entry per word.
--- Returns a list ordered by descending score.
function M.rank(items, query, cfg, ctx)
  ctx.abbreviation_likeness = 1 - skeleton.vowel_ratio(query)

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
  M.apply_context(out, cfg, ctx)
  -- Ties are broken by corpus rank so the order is stable and reproducible.
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return ctx.tiebreak(a) < ctx.tiebreak(b)
  end)
  return out
end

return M
