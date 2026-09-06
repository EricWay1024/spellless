-- Splitting a run of letters back into words: "exactlyright" -> "exactly right".
--
-- Two words is what gets asked for, but two is not actually the easy case --
-- it is the special case.  Finding the best way to cut a string into
-- dictionary words is a word-break dynamic program: for each position, the
-- best segmentation ending there is the best segmentation ending somewhere
-- earlier plus one word.  That costs a lookup per (position, length) pair and
-- handles any number of words, so "iamgoingtoschool" comes out as well.
--
-- What makes it work is not finding *a* segmentation -- for a long string
-- there are usually many -- but preferring the right one.  Two rules do it:
--
--   * common words beat rare ones, by summed log-frequency, so "exactly right"
--     beats "exact ly right" (which is not even valid) and, where both parts
--     are words, the pair that is actually said wins;
--   * each additional word costs something, so a string is not shredded into
--     the many short words English is unfortunately full of.  Without this,
--     "another" happily becomes "an other".

local M = {}

-- Longer than any word worth splitting on, and bounding the inner loop is what
-- keeps this linear in practice.  Not quite "longer than any word in the
-- index": `antidisestablishmentarianism` is 28.  Nothing is lost, because a
-- split needs a second part as well and `max_split_len` is 28 for the whole
-- input, so no reachable split could have used it.
local MAX_WORD = 24

--- Is `part` a word we are willing to build a split out of?
---
--- One-letter parts are refused except for the two that are real words, which
--- matters more than it sounds: allowing any single letter turns the search
--- into an alphabet soup where every string has a segmentation.
local function usable(corpus, part)
  if #part == 1 then
    return (part == "a" or part == "i") and corpus:lookup(part) or nil
  end
  return corpus:lookup(part)
end

--- The best segmentation of `query` into two or more dictionary words, or nil.
---
--- `cfg.split_word_penalty` is charged per word beyond the first: raise it and
--- only the most obvious splits survive, lower it and long strings shatter.
function M.best(corpus, query, cfg)
  local n = #query
  if n < (cfg.min_split_len or 5) or n > (cfg.max_split_len or 28) then
    return nil
  end

  -- score[i] is the best total for the first i characters; from[i] is where
  -- the word ending at i began; ids[i] is that word's dictionary id.
  local score, from, ids = { [0] = 0 }, {}, {}
  for i = 1, n do
    local start = i - MAX_WORD
    if start < 0 then start = 0 end
    for j = start, i - 1 do
      if score[j] then
        local id = usable(corpus, query:sub(j + 1, i))
        if id then
          -- Log-frequency is already what the weight table stores, normalised
          -- to 0..1, so summing weights is summing log-frequencies.
          local total = score[j] + corpus:weight(id) - cfg.split_word_penalty
          if not score[i] or total > score[i] then
            score[i], from[i], ids[i] = total, j, id
          end
        end
      end
    end
  end
  if not score[n] then return nil end

  local parts, word_ids, i = {}, {}, n
  while i > 0 do
    table.insert(parts, 1, query:sub(from[i] + 1, i))
    table.insert(word_ids, 1, ids[i])
    i = from[i]
  end
  if #parts < 2 then return nil end
  return { parts = parts, ids = word_ids, score = score[n] }
end

return M
