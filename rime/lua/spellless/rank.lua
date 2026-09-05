-- Turning candidates from several sources into one ordered list.
--
-- Everything is a single additive score rather than a fixed source ordering,
-- so a very common word reached by a cheap typo can legitimately overtake a
-- rare exact prefix completion.  The per-source base values in config.lua only
-- express the *broad* priority; frequency, edit cost, how much text the
-- completion adds and the user's own history do the fine ordering.

local skeleton = require("spellless.skeleton")

local M = {}

local BASE_KEY = {
  exact    = "base_exact",
  prefix   = "base_prefix",
  typo     = "base_typo",
  skeleton = "base_skeleton",
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
  -- No corpus id means the dictionary does not have this word at all.
  if not item.id then
    s = s - cfg.unknown_word_penalty
  end
  if item.has_form and item.source == "exact" then
    s = s + cfg.form_bonus
  end
  if item.source == "skeleton" then
    -- Signed: a consonant-only input is strong evidence for the abbreviation
    -- reading, a vowel-rich one is evidence against it.
    s = s + cfg.skeleton_vowel_bonus * (2 * ctx.abbreviation_likeness - 1)
  end
  return s
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
  -- Ties are broken by corpus rank so the order is stable and reproducible.
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return ctx.tiebreak(a) < ctx.tiebreak(b)
  end)
  return out
end

return M
