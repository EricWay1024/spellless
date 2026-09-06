local H = require("harness")
local cue = require("spellless.cue")
local config = require("spellless.config")

local cfg = config.build()
local BIG = 99

--- Alignment cost, or nil.  Unbudgeted unless a budget is given.
local function cost(query, word, budget)
  return cue.align(query, word, budget or BIG, cfg)
end

-- The six prices the model derives from its three probabilities.  Keeping a
-- character of class p costs -log(p); dropping it costs -log(1-p); both are
-- divided by the channel's points-per-nat.
local log = math.log
local function keep(p) return -log(p) / cfg.cue_cost_scale end
local function drop(p) return -log(1 - p) / cfg.cue_cost_scale end
local KV, DV = keep(cfg.cue_keep_vowel), drop(cfg.cue_keep_vowel)
local KC, DC = keep(cfg.cue_keep_cluster), drop(cfg.cue_keep_cluster)
local KO, DO = keep(cfg.cue_keep_onset), drop(cfg.cue_keep_onset)

H.suite("cue: the letters typed must appear in the word, in order")
H.eq(cost("tnk", "think") ~= nil, true, "tnk is a subsequence of think")
H.eq(cost("tkn", "think"), nil, "tkn is not: the order is wrong")
H.eq(cost("tnkx", "think"), nil, "a letter the word does not have")
H.eq(cost("hnk", "think"), nil, "the first letter has to match")
H.eq(cost("thinking", "think"), nil, "longer than the word")

H.suite("cue: what each character costs, kept or dropped")
-- The probabilities themselves live in config.lua; what this pins down is
-- which of them each character answers to, because that is the whole model.
H.near(cost("tank", "tank"), KO + KV + 2 * KC, 1e-9,
       "a word typed out in full still pays to keep every letter")
H.near(cost("tnk", "tank"), KO + DV + 2 * KC, 1e-9,
       "and dropping its vowel is the cheap part")
H.near(cost("tnk", "think"), 3 * KC + DC + DV, 1e-9,
       "the h of th is a cluster, the i a vowel")
H.near(cost("ctl", "cattle"), KO + 2 * KC + DC + 2 * DV, 1e-9,
       "one t of a double is a consonant beside a consonant")
H.near(cost("mtl", "material"), 3 * KO + DO + 4 * DV, 1e-9,
       "the r of mate-rial starts a syllable, and dropping that is not free")

H.suite("cue: the model prefers what shorthand actually does")
H.ok(DV < KV, "dropping a vowel is cheaper than typing one")
H.ok(KO < DO, "and keeping a syllable onset is cheaper than dropping it")
-- This is what replaces a global vowel-ratio bonus: the vowels a query
-- *contains* are charged one by one, where they sit.
H.ok(cost("mathe", "matches") > cost("mtch", "matches"),
     "a vowel-rich reading pays for every vowel it kept")

H.suite("cue: the tail is charged, because every character is")
-- Shorthand runs to the end of the word.  Nothing special-cases this: the
-- characters past the last match are dropped characters like any other, and
-- dropping them costs what dropping them costs.
H.ok(cost("embarass", "embarrassed") > cost("embarass", "embarrass"),
     "a word with two letters left over costs more than one with none")
H.ok(cost("tnk", "thinking") > cost("tnk", "think"),
     "and so does a completion of it")

H.suite("cue: one letter of the shorthand may be the wrong key")
-- On by default, and the shipped configuration is what these use.  The
-- switched-off case is asserted separately below, because turning it off is a
-- supported thing to do when a machine has no latency headroom.
local slipcfg = cfg
local SLIP = slipcfg.cue_slip_cost / slipcfg.cue_cost_scale
local function slipcost(query, word, budget)
  return cue.align(query, word, budget or BIG, slipcfg)
end
H.ok(slipcost("stfxctn", "stratification") ~= nil,
     "a slip inside an abbreviation is expensive, not fatal")
H.eq(cue.align("stfxctn", "stratification", 99, config.build{ cue_slip_cost = 0 }), nil,
     "and setting the cost to zero switches the whole thing off again")
H.near(slipcost("gvrnmxt", "government") - slipcost("gvrnmnt", "government"),
       SLIP, 1e-9, "and it costs exactly one slip more than getting it right")
H.eq(slipcost("stfxxtn", "stratification"), nil,
     "two of them are outside the budget")
H.eq(slipcost("tnx", "think"), nil,
     "three letters with one wrong is not a slip, it is a different word")

H.suite("cue: the worked examples")
for _, case in ipairs({
  { "satfcatn", "stratification" }, { "stfcatn", "stratification" },
  { "dfmrphsm", "diffeomorphism" }, { "hmtpy", "homotopy" },
  { "gvmnt", "government" }, { "ppl", "people" },
}) do
  H.ok(cost(case[1], case[2]) ~= nil,
       ("%q aligns onto %q"):format(case[1], case[2]))
end

H.suite("cue: the budget is honoured")
-- The budget is in nats, the cost that comes back is in the ranker's units.
H.eq(cost("tnk", "think", 0.01), nil, "too expensive to report")
H.ok(cost("tnk", "think", 8.0) ~= nil, "affordable at a real budget")

H.suite("cue: the early abort never loses an affordable alignment")
-- The abort is only sound because every price is positive, so the row minimum
-- can only rise as the DP walks the word.  Rather than argue that, check it on
-- random pairs -- half of them clean subsequences, half with one character
-- mutated so the slip transition is the one being exercised.  Whatever budget
-- it is given, the answer must either be exactly the unbudgeted cost or
-- nothing at all, and "nothing at all" must never come back after a budget
-- that could afford it.
--
-- Run with slips enabled, which is the strictly more general DP: the shipped
-- default is the same recurrence with one transition switched off, so soundness
-- here implies soundness there.
do
  math.randomseed(20260906)
  local letters = "aeiourstnlcmdpghbyfwkvxzjq"
  local function subsequence(q, w)
    local i = 1
    for j = 1, #w do
      if w:sub(j, j) == q:sub(i, i) then
        i = i + 1
        if i > #q then return true end
      end
    end
    return false
  end
  local wrong_value, non_monotone, slipped = 0, 0, 0
  for t = 1, 6000 do
    local m = math.random(6, 18)
    local w = {}
    for j = 1, m do
      local k = math.random(#letters)
      w[j] = letters:sub(k, k)
    end
    w = table.concat(w)
    local q = { w:sub(1, 1) }
    for j = 2, m do if math.random() < 0.5 then q[#q + 1] = w:sub(j, j) end end
    if t % 2 == 0 and #q >= 2 then
      local k = math.random(2, #q)
      q[k] = letters:sub(math.random(#letters), math.random(#letters))
    end
    q = table.concat(q)
    if #q >= 2 then
      local full = slipcost(q, w)
      if full then
        if not subsequence(q, w) then slipped = slipped + 1 end
        local seen = false
        for _, b in ipairs({ 0.5, 1.5, 3, 5, 8, 12, 20, 40 }) do
          local got = slipcost(q, w, b)
          if got and math.abs(got - full) > 1e-9 then wrong_value = wrong_value + 1 end
          if seen and not got then non_monotone = non_monotone + 1 end
          if got then seen = true end
        end
      end
    end
  end
  H.eq(wrong_value, 0, "no budget ever changed the cost it reported")
  H.eq(non_monotone, 0, "and no budget refused what a smaller one afforded")
  H.ok(slipped > 50, "the mutated half really did exercise the slip transition")
end

H.suite("cue: scratch space does not leak between calls")
-- The byte and price arrays outlive each call, so a long word followed by a
-- short one used to see the long one's characters off the end of the short.
local long_first = cost("aaz", "aardvarkz")
H.ok(long_first ~= nil, "a long word first")
H.near(cost("tnk", "tank"), KO + DV + 2 * KC, 1e-9, "then a short one, unaffected")
H.near(cost("aaz", "aardvarkz"), long_first, 1e-9, "and back again")
