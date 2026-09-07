-- What the text already in the document implies for what comes next: whether a
-- space belongs after it, whether it starts a sentence, and whether a mark
-- about to be typed belongs flush against the word behind it.
--
-- Pure string inspection, no Rime dependency.  Deciding *which* text to hand
-- it is the adapter's job, and the harder half of the problem -- see
-- spellless.lua.

local M = {}

local byte, sub = string.byte, string.sub

-- Characters that a following word should sit flush against.  Opening
-- brackets and quotes, the joiners inside compound words and identifiers, and
-- anything that is already whitespace.
local NO_SPACE_AFTER = {}
for c in ("([{<-/@#~*_=+\\|"):gmatch(".") do NO_SPACE_AFTER[byte(c)] = true end
for c in (" \t\n\r"):gmatch(".") do NO_SPACE_AFTER[byte(c)] = true end

-- Marks that could be opening or closing.  They open when nothing, a space or
-- a bracket precedes them, and close otherwise -- so `he said "` gets no space
-- and `"no."` does.  The dollar is here for inline LaTeX (`Let $` must hug the
-- next word and `$X$` must not, the single most common delimiter in a
-- mathematician's prose) and the backtick for Markdown code spans.
local PAIRED = {}
for c in ("\"'$`"):gmatch(".") do PAIRED[byte(c)] = true end

local function is_space(c)
  return c == 32 or c == 9 or c == 10 or c == 13
end

--- Does the delimiter run ending at `i` open rather than close?
---
--- Run-aware, because `$$` and ``` `` ``` are single delimiters written twice:
--- looking only at the character before the last `$` would see another `$`,
--- call it closing, and put a space inside `$$ x $$`.
local function opens(previous, i)
  local mark = byte(previous, i)
  while i > 1 and byte(previous, i - 1) == mark do i = i - 1 end
  if i == 1 then return true end
  local before = byte(previous, i - 1)
  return is_space(before)
      or before == byte("(") or before == byte("[") or before == byte("{")
end

-- Closing marks that may sit between the full stop and the next word:
--   He said "no."   ->  still the end of a sentence
local CLOSERS = {}
for c in ("\"')]}"):gmatch(".") do CLOSERS[byte(c)] = true end

local TERMINATORS = {}
for c in (".!?"):gmatch(".") do TERMINATORS[byte(c)] = true end

-- Marks that belong to the word in front of them, so an automatic space
-- already committed after that word should be taken back.  See hugs_previous.
--
-- Two kinds.  Sentence punctuation and closing brackets, which then want a
-- space of their own; and the joiners that build compound words, which do not.
-- `well-known`, `and/or` and `foo_bar` are the overwhelmingly common reading
-- after a word; a spaced dash is not what someone types a hyphen for.
-- Deliberately absent: `=` `+` `*` `~`, which are arithmetic and LaTeX, where
-- the spaces around them are wanted.
local HUGS_PREVIOUS = {}
for c in (".,;:!?)]}"):gmatch(".") do HUGS_PREVIOUS[byte(c)] = true end
for c in ("-/_"):gmatch(".") do HUGS_PREVIOUS[byte(c)] = true end

-- Marks that open something, so the word before them keeps its space:
-- `see (the)`, never `see(the)`.
local OPENERS = {}
for c in ("([{<"):gmatch(".") do OPENERS[byte(c)] = true end

--- Should a space follow the text committed so far?
---
--- Asked of a word about to be committed (which then carries the space) and of
--- a punctuation mark about to be written, always with enough of the text
--- behind it to judge the ambiguous marks -- a lone `$` reads as opening, so
--- the closing one in `$X$` would otherwise never get the space after it.
function M.needs_space_after(previous)
  if not previous or previous == "" then return false end
  local n = #previous
  local last = byte(previous, n)
  if PAIRED[last] then return not opens(previous, n) end
  if NO_SPACE_AFTER[last] then return false end
  -- Anything outside ASCII is CJK or CJK punctuation, which brings its own
  -- spacing conventions; adding a Latin space there is wrong.
  if last >= 0x80 then return false end
  return true
end

--- Does `previous` finish a sentence, so that the next word wants a capital?
---
--- Trailing whitespace and closing quotes or brackets are stepped over first.
---
--- `abbreviations` is an optional set of exact strings whose trailing full stop
--- does *not* end a sentence.  It is how "e.g." stops looking like the end of
--- one: because Spellless commits it as a single candidate rather than as
--- three keystrokes, the whole abbreviation is there to recognise.  Anything
--- typed dot by dot is still indistinguishable from a full stop, exactly as it
--- is in every word processor.
function M.ends_sentence(previous, abbreviations)
  if not previous or previous == "" then return false end

  -- Step back over trailing space and closing marks first, so that
  --   He said "no."   and   ... (e.g.)
  -- are both judged on the "no." and the "(e.g." underneath.  Doing the
  -- abbreviation test before this strip is what made the parenthesised form --
  -- much the commonest one -- start a new sentence.
  local i = #previous
  while i >= 1 do
    local c = byte(previous, i)
    -- Openers as well as closers: `no. (the` is still a new sentence, while
    -- `Hello (the` correctly is not, because what remains under the bracket is
    -- a word rather than a full stop.
    if CLOSERS[c] or OPENERS[c] or is_space(c) then i = i - 1 else break end
  end
  if i < 1 then return false end

  if abbreviations then
    -- Matched as a suffix and case-insensitively: the caller passes a tail of
    -- several commits, and an abbreviation at the start of a sentence has
    -- already been capitalised to "E.g.".
    local core = previous:sub(1, i):lower()
    for abbreviation in pairs(abbreviations) do
      if #core >= #abbreviation and core:sub(-#abbreviation) == abbreviation then
        return false
      end
    end
  end
  return TERMINATORS[byte(previous, i)] == true
end

--- Should `mark` sit flush against the word before it, close enough that an
--- automatic space already committed after that word should be taken back?
---
--- The dual of needs_space_after, and only ever asked when such a space is
--- actually there: `you ` + `.` wants it back, `you ` + `(` does not.
---
--- The mark alone decides, and the paired marks are deliberately absent.  They
--- are the ones `opens` disambiguates by looking at the character behind them,
--- and here that character is the very space in question: strip it and `he
--- said "` and `"no." ` are indistinguishable from behind.  Guessing would
--- either weld an opening quote to the previous word or pull a closing one out
--- of its own sentence, so neither is touched.  A quote typed mid-word never
--- reaches this question anyway -- it ends the composition, which drops the
--- space rather than reclaiming it.
function M.hugs_previous(mark)
  if not mark or mark == "" then return false end
  return HUGS_PREVIOUS[byte(mark, 1)] == true
end

--- Does `mark` open something, so the word in front of it keeps its space?
---
--- The mirror of hugs_previous, asked while a word is still composing: every
--- other mark ends the word flush against it, but `see` + `(` must not become
--- `see(`.
function M.opens_after_word(mark)
  if not mark or mark == "" then return false end
  return OPENERS[byte(mark, 1)] == true
end

--- Is there nothing behind the cursor but the start of a sentence?
---
--- Opening brackets and quotes are stepped over: `(the` at the top of a
--- document is still the first word of a sentence, and so is `"the`.
function M.starts_fresh(previous)
  if not previous or previous == "" then return true end
  for i = 1, #previous do
    local c = byte(previous, i)
    if not (is_space(c) or OPENERS[c] or PAIRED[c]) then return false end
  end
  return true
end

--- The word immediately before the caret, when there is one and it is cleanly
--- separated from what is about to be typed.
---
--- Deliberately strict, because this is read for its part of speech and a wrong
--- reading is worse than none.  Exactly one space, and only letters and inner
--- apostrophes before it:
---
---   "the "        -> "the"
---   "of the "     -> "the"
---   "don't "      -> "don't"
---   "the  "       -> nil    two spaces is a paste or a layout, not prose
---   "the"         -> nil    still being typed, or a caret mid-word
---   "the, "       -> nil    a comma is a boundary the class table cannot read
---   "(the) "      -> nil    same
---   ""            -> nil
---
--- Punctuation is rejected rather than stepped over on purpose: "after the
--- meeting, generate" and "after the meeting generate" are different sentences,
--- and a bracket or a full stop between the two words means the previous word
--- is not the one predicting this one.
function M.previous_word(previous)
  if not previous or previous == "" then return nil end
  if byte(previous, #previous) ~= 32 then return nil end
  if #previous >= 2 and is_space(byte(previous, #previous - 1)) then return nil end
  local word = previous:sub(1, -2):match("([%a][%a']*)$")
  if not word then return nil end
  -- The match above stops at any non-letter, so anything else immediately in
  -- front of the word -- a digit, a bracket, a hyphen -- has already been
  -- excluded by it.  What it cannot see is a trailing apostrophe, which is a
  -- closing quote far more often than it is a possessive.
  if word:sub(-1) == "'" then return nil end
  return word
end

--- Is the user part-way through something we must not guess at?
---
--- A backslash means a LaTeX control sequence has started: `\citep` must not
--- become `\cited`.  The backslash is committed as punctuation before the
--- letters are composed, so it is only visible here, in the text behind.
function M.expects_literal(previous)
  if not previous or previous == "" then return false end
  return byte(previous, #previous) == byte("\\")
end

-- Where English requires a bare infinitive.
--
-- A closed class, and that is the entire reason this is worth doing: a rule
-- that fires after every word is a statistical preference and loses (see
-- docs/ALGORITHM.md 8.1), while one that fires only where the grammar is
-- actually forced is a constraint and does not.  Everything below was measured
-- on 427,000 words of the prose this is for, and the rate quoted is how often
-- an -ed inflection really does turn up in that slot:
--
--   a modal                 2,598 slots   0.5%
--   modal + adverbs           518 slots   0.8%
--   `to`, licensed            856 slots   0.1%
--   ------------------------------------------- the line, and what is over it
--   `to`, unlicensed        5,670 slots   1.4%
--   have / has / had        1,296 slots   6.6%
--   a / an                 17,306 slots   5.4%
--
-- `have` and `is` take a past participle rather than a bare form, and `a`/`an`
-- are followed by participial adjectives all day long -- `an ordered pair`, `a
-- related result`.  They are not near misses; they are the rule's opposite.
local MODAL = {}
for word in ([[would could should must may might shall will can cannot
               wouldn't couldn't shouldn't mustn't mightn't mayn't
               shan't won't can't]]):gmatch("[%a']+") do
  MODAL[word] = true
end

-- `to` is the infinitive marker about a seventh of the time and a preposition
-- otherwise, and in mathematics the preposition dominates: `isomorphic to`,
-- `with respect to`, `restricts to`, `due to`.  The word in front of it is the
-- only local evidence, and it is enough -- licensing on this list takes the
-- -ed rate in the slot from 1.4% to 0.1%, which is cleaner than the modals.
local TO_LICENSOR = {}
for word in ([[want wants wanted need needs needed able unable try tries tried
               trying have has had having going go goes seems seem seemed
               appears appear likely unlikely enough used easy hard difficult
               possible impossible order wish wishes hope hopes hoped aim aims
               aimed intend intends intended attempt attempts attempted decide
               decides decided choose chooses chose fail fails failed manage
               manages managed allow allows allowed require requires required
               suffices suffice remains remain ought how what where whether
               tends tend tended prefer prefers preferred continue continues
               continued expect expects expected seek seeks sought]]):gmatch("%a+") do
  TO_LICENSOR[word] = true
end

-- Adverbs stand between the trigger and the verb -- "would not relate", "could
-- also deduce", "may in fact hold" -- and skipping them is worth a fifth again
-- as many slots at the same error rate.
--
-- The chain stops of its own accord at exactly the right place, which is worth
-- noticing: `be` and `have` are not adverbs, so "would be related" and "would
-- have related" -- both perfectly good English -- are never reached.
local ADVERB = {}
for word in ([[not never always also still only just probably certainly
               therefore thus then now well further again instead actually
               indeed perhaps simply readily generally usually often sometimes
               rather even already hardly barely nevertheless otherwise
               however hence first later soon almost nearly quite very]]):gmatch("%a+") do
  ADVERB[word] = true
end

-- Adverbials that are two words rather than one.  "may in fact hold" is the
-- commonest thing standing between a modal and its verb in this prose after
-- the plain adverbs, and `in` alone must not be skippable -- "interested in
-- related work" is not a bare-verb slot.
local IN_PHRASE = {}
for word in ("fact particular general principle turn practice addition effect"):gmatch("%a+") do
  IN_PHRASE[word] = true
end

-- Everything else ending in -ly is an adverb, an adjective or a noun, and only
-- a verb can be what a modal is waiting for -- so the pattern is safe as long
-- as the English verbs ending in -ly are named.  There are sixteen, and the
-- exception is not hypothetical: `apply`, `imply` and `rely` all turn up in
-- the verb slot in the sample.  The pattern is worth 65 more slots than the
-- list alone, and more than that in prose less clipped than a maths notebook.
local LY_VERB = {}
for word in ("apply comply imply multiply ply reply rely supply fly rally tally dally sally bully sully ally"):gmatch("%a+") do
  LY_VERB[word] = true
end

local function adverbial(word)
  if ADVERB[word] then return true end
  return #word > 3 and word:sub(-2) == "ly" and not LY_VERB[word]
end

-- How many adverbs may stand between the trigger and the verb, and how much
-- text is read to find them.  Three is past the point of diminishing returns
-- ("would not in fact simply relate") and the bound matters: this runs on
-- every keystroke.
local ADVERB_CHAIN = 3
local LOOKBACK = 96

--- Does the text behind the caret call for a bare verb?
---
--- Nil-safe, and silent by default: anything it cannot read confidently is a
--- `false`, which is the same answer as an ordinary word and costs nothing.
function M.expects_bare_verb(previous)
  if not previous or previous == "" then return false end
  -- A frontend that turns apostrophes into typographic ones must not be
  -- able to hide "wouldn't" from this.
  local tail = previous:lower():gsub('\226\128\153', "'")
  if #tail > LOOKBACK then tail = tail:sub(-LOOKBACK) end
  -- Only the current sentence.  Otherwise "we could. However, related work..."
  -- walks back over the full stop and demotes a word in a new sentence.
  tail = tail:match("[^.!?;:]*$")

  -- Tokens, with the gap that follows each, because the gaps decide as much as
  -- the words do: "would relate" is a bare slot and "would-relate" is not.
  local words, gaps, n = {}, {}, 0
  local pos = 1
  while true do
    local a, b = tail:find("[%a']+", pos)
    if not a then break end
    n = n + 1
    words[n] = tail:sub(a, b)
    if n > 1 then gaps[n - 1] = tail:sub(pos, a - 1) end
    pos = b + 1
  end
  if n == 0 then return false end
  -- Whatever follows the last word, up to the caret.  A space, or a comma and
  -- a space; anything else -- a bracket, a dash, a digit -- and the word in
  -- front is not the word in front of the *verb*.
  if not tail:sub(pos):match("^[%s,]*$") then return false end

  local i, steps = n, 0
  while i >= 1 and steps <= ADVERB_CHAIN do
    local word = words[i]
    if MODAL[word] then return true end
    if word == "to" then return TO_LICENSOR[words[i - 1] or ""] == true end
    if i > 1 and IN_PHRASE[word] and words[i - 1] == "in" then
      i = i - 2
    elseif adverbial(word) then
      i = i - 1
    else
      return false
    end
    -- The gap the step just crossed.  A comma is allowed -- "would, however,
    -- relate" is one clause -- and a bracket or a dash is not.
    if i >= 1 and not gaps[i]:match("^[%s,]*$") then return false end
    steps = steps + 1
  end
  return false
end

--- Also used by the tests to document the contract for CJK text.
M.CLOSERS, M.TERMINATORS = CLOSERS, TERMINATORS
M.HUGS_PREVIOUS, M.OPENERS = HUGS_PREVIOUS, OPENERS

return M
