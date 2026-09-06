-- A coarse part-of-speech class for a word, and what the word before it says
-- about which class should come next.
--
-- The premise (§8.1 of docs/ALGORITHM.md, sharpened by review): the largest
-- remaining failure class is morphological siblings -- "regulator" beating
-- "regulatory", "generate" beating "generation" -- where the input
-- under-determines the suffix and the commoner sibling wins.  Siblings almost
-- always differ in part of speech, and the previous word predicts part of
-- speech far better than it predicts the word.  So: one coarse class per
-- candidate, a class-by-class log-ratio against the previous word's class, and
-- a term worth `context_weight` points per nat.
--
-- Everything here is hand-written.  There is no tagged lexicon in this repo and
-- no network, so the class function is English suffix morphology plus a closed
-- list, and the log-ratios are priors written down by hand rather than counted.
--
-- MEASURED, AND IT DOES NOT PAY.  `lua bench/context.lua` runs the whole case
-- set again under each of six fixed previous words.  At every weight and every
-- margin tried, and for every previous word the table has an opinion about, it
-- breaks more answers than it fixes -- 9 fixed against 29 broken after "the",
-- the commonest word in English, at the constants below.  So the flag is off,
-- and the reason is worth writing down because it is not a tuning failure:
--
--   the PMI table was written about parts of speech, and the suffix rules do
--   not select parts of speech.  "VERB" here means "ends in -ed, -ing or -ate",
--   and P(that | "the") is nothing like P(verb | "the") -- "the building", "the
--   greeting", "the finished draft" are all ordinary English.  Two classifiers
--   are involved and only one of them was measured.
--
-- The fix is the one the review actually asked for: count the table from a
-- tagged lexicon, using the same classes the runtime will assign.  Until then
-- the honest reading is that this measures the prior and not the language.
-- What survives is the shape -- a zero-centred log-ratio, gated, margin-bounded
-- -- which is what a real table would drop into unchanged.
--
-- Pure string work: no corpus, no dependency, no allocation per call beyond the
-- lowercasing.

local M = {}

-- ---------------------------------------------------------------------------
-- the class of a candidate
-- ---------------------------------------------------------------------------

-- Four open classes are all a suffix rule can hope to tell apart.  A candidate
-- that matches nothing gets nil, which means "no opinion" and scores zero --
-- never a default of NOUN, because a default is an opinion.
M.NOUN, M.VERB, M.ADJ, M.ADV = "NOUN", "VERB", "ADJ", "ADV"

-- Words whose class no suffix can reach.  Only what is needed to recognise the
-- *previous* word plus the handful of closed-class candidates that turn up in
-- the case files; a fuller list would be a lexicon, which is the thing this
-- design is doing without.
local CLOSED = {}
local function closed(cls, words)
  for w in words:gmatch("%S+") do CLOSED[w] = cls end
end

closed("DET", "the a an this that these those my your his her its our their "
           .. "some any no every each another both all such")
closed("PREP", "of in on at to for with from by about into onto over under "
            .. "after before between through during against without within "
            .. "among across upon toward towards behind beyond near per via "
            .. "off out up down")
closed("PRON", "i you he she it we they me him us them who whom whose what "
            .. "which someone something anything everything nothing himself "
            .. "herself itself themselves myself yourself")
closed("CONJ", "and or but if because while although though since unless "
            .. "whether nor so when where than as")
closed("AUX", "is are was were be been being am has have had do does did will "
           .. "would can could shall should may might must ought")
closed("ADV", "very more most quite rather too also only just even still well "
           .. "not never always often sometimes really extremely fairly "
           .. "somewhat")

-- Suffix rules, tried in order: longest and most specific first.  Each is
-- (suffix, class, shortest word it may fire on) -- the length floor is what
-- stops "or" classifying "for" and "ed" classifying "red".
--
-- This list is deliberately frozen at the version whose separation rate was
-- measured before any of the ranking code existed, so that the reported ceiling
-- and the shipped rule are the same rule.  Its known errors are listed at the
-- bottom of this file.
local SUFFIX = {
  { "ously", M.ADV, 6 }, { "ically", M.ADV, 7 }, { "fully", M.ADV, 6 },
  { "ly", M.ADV, 4 },

  { "ation", M.NOUN, 6 }, { "ition", M.NOUN, 6 }, { "tion", M.NOUN, 5 },
  { "sion", M.NOUN, 5 }, { "ness", M.NOUN, 5 }, { "ment", M.NOUN, 5 },
  { "ity", M.NOUN, 5 }, { "ance", M.NOUN, 5 }, { "ence", M.NOUN, 5 },
  { "ship", M.NOUN, 6 }, { "hood", M.NOUN, 6 }, { "dom", M.NOUN, 5 },
  { "ism", M.NOUN, 5 }, { "ist", M.NOUN, 5 }, { "ogy", M.NOUN, 5 },
  { "ure", M.NOUN, 5 }, { "cy", M.NOUN, 5 },

  { "able", M.ADJ, 5 }, { "ible", M.ADJ, 5 }, { "less", M.ADJ, 5 },
  { "ful", M.ADJ, 5 }, { "ous", M.ADJ, 5 }, { "ive", M.ADJ, 5 },
  { "ary", M.ADJ, 5 }, { "ory", M.ADJ, 5 }, { "ish", M.ADJ, 5 },
  { "ical", M.ADJ, 6 }, { "al", M.ADJ, 5 }, { "ic", M.ADJ, 5 },
  { "ent", M.ADJ, 5 }, { "ant", M.ADJ, 5 }, { "ian", M.ADJ, 5 },
  { "an", M.ADJ, 5 },

  { "ate", M.VERB, 5 }, { "ise", M.VERB, 5 }, { "ize", M.VERB, 5 },
  { "ify", M.VERB, 5 }, { "ing", M.VERB, 5 }, { "ed", M.VERB, 4 },

  -- -er and -or are agent nouns far more often than not, but "offer",
  -- "cover", "remember" and "order" are verbs.  The crudest rule here.
  { "er", M.NOUN, 5 }, { "or", M.NOUN, 5 },

  -- Last resort: a trailing s on something long enough is a plural noun.  It
  -- is a third-person verb about as often, which this cannot see.
  { "es", M.NOUN, 4 }, { "s", M.NOUN, 4 },
}

--- The coarse class of `word`, or nil when nothing fires.
---
--- Apostrophes and spaces are dropped first so that a surface form is judged on
--- its letters: "don't" is "dont", "in front of" is "infrontof".
function M.of(word)
  if not word or word == "" then return nil end
  local w = word:lower():gsub("[' ]", "")
  if w == "" then return nil end
  local c = CLOSED[w]
  if c then return c end
  local n = #w
  for i = 1, #SUFFIX do
    local rule = SUFFIX[i]
    local suf = rule[1]
    if n >= rule[3] and w:sub(-#suf) == suf then return rule[2] end
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- what the previous word predicts
-- ---------------------------------------------------------------------------

-- The previous word is read as one of five context classes.  Anything else --
-- which is most of English -- is nil and contributes nothing at all, which is
-- the point of using a log-ratio rather than a log-probability.
--
-- NEUTRAL is not an oversight.  "and", "or" and "but" predict the class of
-- whatever preceded *them*, which is exactly the thing we cannot see, so they
-- are named and given an empty row rather than left to fall through to some
-- other rule later.
local CONTEXT = {}
local function context(cls, words)
  for w in words:gmatch("%S+") do CONTEXT[w] = cls end
end

context("DET", "the a an this that these those my your his her its our their "
            .. "every each another")
context("PREP", "of in on at for with from by into about over under after "
             .. "before between through during against without within among "
             .. "across upon")
context("DEG", "very more most quite rather")
context("NEUTRAL", "and or but")
-- "to" is both the infinitive marker and a preposition, and one previous word
-- cannot say which.  It gets a row of its own that leans to the verb without
-- condemning the noun, rather than being forced into either the PREP row (which
-- would fight "to generate") or a verb row (which would fight "to school").
context("TO", "to")

--- The context class of the word before this one, or nil.
function M.context_of(word)
  if not word or word == "" then return nil end
  return CONTEXT[word:lower()]
end

-- Pointwise mutual information, log P(class | previous) - log P(class), in
-- nats, for the four open classes.  Written down rather than counted: the
-- conditional halves are rough English priors (after a determiner, roughly 70%
-- of next tokens are nouns and 25% adjectives), the marginals are roughly
-- NOUN .45  VERB .25  ADJ .20  ADV .10.
--
-- Clamped to +/-1.5.  A hand-written prior has no business being more certain
-- than the evidence in the input, and log(.01/.25) = -3.2 for a verb after a
-- determiner is exactly that kind of certainty.  Unlisted pairs are 0.
--
-- Zero-centred by construction: an unknown previous word has no row, an
-- unclassifiable candidate has no column, and either way the term is exactly 0.
local PMI = {
  DET  = { NOUN =  0.44, ADJ =  0.22, ADV = -0.92, VERB = -1.50 },
  PREP = { NOUN =  0.47, ADJ = -0.10, ADV = -0.92, VERB = -1.43 },
  TO   = { VERB =  0.79, NOUN = -0.25, ADJ = -1.05, ADV = -1.20 },
  DEG  = { ADJ  =  1.13, ADV =  0.92, VERB = -1.50, NOUN = -1.50 },
  NEUTRAL = {},
}

--- PMI between the previous word's context class and a candidate's class.
--- Zero whenever either side has nothing to say.
function M.pmi(previous_class, candidate_class)
  if not previous_class or not candidate_class then return 0 end
  local row = PMI[previous_class]
  if not row then return 0 end
  return row[candidate_class] or 0
end

-- Known failure modes of the class function, none of them fixed here because
-- fixing them after reading the case files is how a measurement becomes a fit:
--
--   * "vegetable" -> ADJ and "adjutant" -> ADJ: -able and -ant are adjective
--     suffixes that also end common nouns.
--   * "mathematician" -> ADJ: -ician is an agent noun; only -ian is listed.
--   * "Hungary" -> ADJ and "hungry" -> nil: -ary fires on a proper noun and
--     nothing fires on the adjective.  Inverted, which is worse than silent.
--   * "observed"/"observe", "effects"/"effect", "breakfasts"/"breakfast":
--     separated, but by tense and number rather than by part of speech.  The
--     class term will happily reorder these on no evidence at all.
--   * every proper noun: nil, or whatever its ending happens to look like.

M.CLOSED, M.SUFFIX, M.CONTEXT, M.PMI = CLOSED, SUFFIX, CONTEXT, PMI

return M
