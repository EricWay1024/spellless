-- The static dictionary and its indexes.
--
-- Everything here is loaded once per Lua state and shared by every translator
-- instance (Weasel runs a single Lua state for the whole process, but creates
-- one engine per input context, so `Corpus.load` memoises on the data path).
--
-- Files, all produced by scripts/build_dictionary.py + scripts/build_indexes.py:
--
--   spellless.words    newline separated, most frequent first.  A word's id is
--                      its 1-based line number, so a smaller id means a more
--                      common word and ranges can be ranked without a sort.
--   spellless.weights  one byte per word: log-frequency rescaled onto 0..255.
--   spellless.alpha    u24 word ids sorted alphabetically  -> exact + prefix
--   spellless.skel     u24 word ids sorted by skeleton      -> consonant input
--
-- Derived at load time because it is cheaper than shipping and parsing
-- (measured ~55 ms for 83k words, once):
--
--   masks     26-bit letter-presence bitmask per word, for the scan prefilter
--   buckets   word ids grouped by (word length, first letter) and by
--             (skeleton length, first letter), each already frequency ordered

local util = require("spellless.util")
local skeleton = require("spellless.skeleton")

local byte, unpack_u24 = string.byte, string.unpack

-- bit positions of a e i o u within the 26-bit letter mask
local VOWEL_BITS = (1 << 0) | (1 << 4) | (1 << 8) | (1 << 14) | (1 << 20)

local Corpus = {}
Corpus.__index = Corpus

local cache = {}

--- Bucket key for a (length, first letter) pair.  Lengths above 31 are folded
--- into 31; no English word we index is that long.
local function bucket_key(len, first_byte)
  if len > 31 then len = 31 end
  return len * 32 + (first_byte - 96)
end
Corpus.bucket_key = bucket_key

--- Everything cheap enough to derive from the word list rather than ship it.
---
--- One pass, and it is the same pass for the shipped dictionary and for the
--- personal one.  The two used to have separate matchers and the personal half
--- was a linear scan with a cap on it, which is how a word you had taught the
--- system became unreachable by shorthand once you had taught it enough
--- others.  There is one matcher now, so there is one indexer.
local function derive(self)
  local words, n = self.words, self.n
local masks, smasks, wbuckets, sbuckets = {}, {}, {}, {}
for id = 1, n do
  local w = words[id]
  local len = #w
  local mask, vowels = 0, 0
  for k = 1, len do
    local c = byte(w, k)
    if c >= 97 and c <= 122 then
      mask = mask | (1 << (c - 97))
      if c == 97 or c == 101 or c == 105 or c == 111 or c == 117 then
        vowels = vowels + 1
      end
    end
  end
  masks[id] = mask
  local first = byte(w, 1)
  -- Letters that survive into the skeleton: the consonants, plus the first
  -- character when it happens to be a vowel.
  local smask = mask & ~VOWEL_BITS
  if first == 97 or first == 101 or first == 105 or first == 111 or first == 117 then
    smask = smask | (1 << (first - 97))
  end
  smasks[id] = smask
  local wk = bucket_key(len, first)
  local b = wbuckets[wk]
  if not b then b = {}; wbuckets[wk] = b end
  b[#b + 1] = id
  -- Skeleton length without building the string: every character survives
  -- except the vowels after the first one (see spellless.skeleton).
  local slen = len - vowels
  if first == 97 or first == 101 or first == 105 or first == 111 or first == 117 then
    slen = slen + 1
  end
  local sk = bucket_key(slen, first)
  b = sbuckets[sk]
  if not b then b = {}; sbuckets[sk] = b end
  b[#b + 1] = id
end
  self.masks, self.smasks = masks, smasks
  self.wbuckets, self.sbuckets = wbuckets, sbuckets
  self.skel_cache, self.skel_cached = {}, 0
end

--- A corpus-shaped index over a word list already in memory.
---
--- The personal store uses this: same masks, same buckets, same range
--- searches, same `generate.generate`, so a name you taught the system is
--- found by exactly the machinery that finds a dictionary word.  Word ids here
--- index `words`, not the shipped dictionary -- the caller maps them back.
---
--- No frequency data, because there is none to have: a flat weight leaves the
--- ordering to `cost` and to the personal counts, which is what should decide
--- between two words you chose yourself.
function Corpus.of_words(words)
  local self = setmetatable({ words = words, n = #words,
                              forms = {}, abbreviations = {} }, Corpus)
  self.skel_cache, self.skel_cached = {}, 0
  local alpha, skel, skels = {}, {}, {}
  for i = 1, self.n do
    alpha[i], skel[i] = i, i
    skels[i] = skeleton.of(words[i])
  end
  table.sort(alpha, function(a, b) return words[a] < words[b] end)
  table.sort(skel, function(a, b)
    if skels[a] ~= skels[b] then return skels[a] < skels[b] end
    return a < b
  end)
  -- Instance fields shadow the metatable, so the shipped corpus keeps reading
  -- its packed blobs and pays nothing for this.
  self.alpha_at = function(_, i) return alpha[i] end
  self.skel_at  = function(_, i) return skel[i] end
  self.weight   = function() return 0.5 end
  derive(self)
  return self
end

--- A cheap stand-in for "are these the same files as last time": the sizes of
--- everything the corpus is built from.
---
--- The alternative is to trust the directory name, and that is how a rebuilt
--- dictionary used to go unnoticed: the process had already loaded the old one
--- and simply kept it.  The failure is quiet and confusing, because the word
--- list and the indexes are then a matched pair of the *wrong* generation --
--- ids resolve to whatever word now sits at that position, so a query lands on
--- an unrelated word rather than on nothing at all.
function Corpus.fingerprint(dir)
  local parts = {}
  for _, name in ipairs({ "spellless.words", "spellless.weights",
                          "spellless.alpha", "spellless.skel",
                          "spellless.forms" }) do
    local fh = io.open(util.join(dir, name), "rb")
    local size = -1
    if fh then
      size = fh:seek("end") or -1
      fh:close()
    end
    parts[#parts + 1] = tostring(size)
  end
  return table.concat(parts, ":")
end

--- Load the corpus from `dir`, memoised per directory *and* generation of the
--- files in it, so a redeploy takes effect without restarting anything.
function Corpus.load(dir)
  local key = dir .. "\0" .. Corpus.fingerprint(dir)
  if cache[key] then return cache[key] end

  local words_blob, err = util.slurp(util.join(dir, "spellless.words"))
  if not words_blob then
    return nil, "cannot read spellless.words: " .. tostring(err)
  end

  local self = setmetatable({ dir = dir }, Corpus)

  -- [^\r\n]+ rather than [^\n]+: this file is shipped to Windows, where a
  -- checkout with core.autocrlf on turns every line ending into CRLF.  Keeping
  -- the carriage return made exact lookup fail and put a \r inside every
  -- committed word.
  local words, n = {}, 0
  for w in words_blob:gmatch("[^\r\n]+") do
    n = n + 1
    words[n] = w
  end
  self.words, self.n = words, n

  self.weights = util.slurp(util.join(dir, "spellless.weights"))
  self.alpha_blob = util.slurp(util.join(dir, "spellless.alpha"))
  self.skel_blob = util.slurp(util.join(dir, "spellless.skel"))
  if not (self.weights and self.alpha_blob and self.skel_blob) then
    return nil, "generated index files are missing from " .. dir
  end
  -- Exact sizes, not minimums.  A *longer* stale index passes a minimum check
  -- and then hands out word ids past the end of the list, which surfaces much
  -- later as a nil comparison deep in a binary search.
  if #self.weights ~= n or #self.alpha_blob ~= n * 3 or #self.skel_blob ~= n * 3 then
    return nil, ("generated files disagree: %d words, %d weights, %d+%d index entries")
        :format(n, #self.weights, #self.alpha_blob // 3, #self.skel_blob // 3)
  end

  derive(self)
  -- Surface forms.  Optional: an older generated/ directory simply has none.
  -- A form that ends in a full stop is an abbreviation, and committing one
  -- must not be read as the end of a sentence -- see spellless.preceding.
  self.forms, self.abbreviations = {}, {}
  local forms_blob = util.slurp(util.join(dir, "spellless.forms"))
  if forms_blob then
    for key, display in forms_blob:gmatch("([^\t\r\n]+)\t([^\r\n]+)") do
      self.forms[key] = display
      -- Stored lower case; spellless.preceding matches case-insensitively so
      -- that a sentence-initial "E.g." is recognised too.
      if display:sub(-1) == "." then self.abbreviations[display:lower()] = true end
    end
  end

  cache[key] = self
  return self
end

--- Normalised corpus frequency of a word, in [0, 1].
function Corpus:weight(id)
  return byte(self.weights, id) / 255
end

-- Above this many remembered skeletons the cache is dropped rather than grown.
-- Reaching it takes tens of thousands of distinct queries; the cost of
-- refilling lazily is far smaller than holding a second copy of the corpus.
local SKELETON_CACHE_LIMIT = 30000

--- Skeleton of word `id`, computed on demand and remembered.  Only the few
--- thousand words a session actually scans ever get one.
function Corpus:skeleton(id)
  local s = self.skel_cache[id]
  if not s then
    s = skeleton.of(self.words[id])
    if self.skel_cached >= SKELETON_CACHE_LIMIT then
      self.skel_cache, self.skel_cached = {}, 0
    end
    self.skel_cache[id] = s
    self.skel_cached = self.skel_cached + 1
  end
  return s
end

function Corpus:alpha_at(i) return unpack_u24("<I3", self.alpha_blob, (i - 1) * 3 + 1) end
function Corpus:skel_at(i)  return unpack_u24("<I3", self.skel_blob,  (i - 1) * 3 + 1) end

-- ---------------------------------------------------------------------------
-- range searches over the two precomputed permutations
-- ---------------------------------------------------------------------------

--- First position where `is_before(key)` stops holding.
---
--- A predicate rather than a target string on purpose: bounding a prefix range
--- with sentinel bytes like "\0" and "\255" would make the result depend on
--- how the host collates them, and Lua compares strings with `strcoll`.  With
--- a predicate every bound is expressed in terms of `<` between real words and
--- an exact prefix test, both of which mean the same thing everywhere.
---
--- `is_before` must be monotone along the permutation, and `key_at(self, i)`
--- maps a position to the string it is sorted by.
local function partition_point(self, key_at, is_before)
  local lo, hi = 1, self.n + 1
  while lo < hi do
    local mid = (lo + hi) // 2
    if is_before(key_at(self, mid)) then lo = mid + 1 else hi = mid end
  end
  return lo
end

local function alpha_key(self, i) return self.words[self:alpha_at(i)] end
local function skel_key(self, i) return self:skeleton(self:skel_at(i)) end

local function starts_with(s, prefix) return s:sub(1, #prefix) == prefix end

--- Word id of an exact spelling, or nil.
function Corpus:lookup(word)
  local i = partition_point(self, alpha_key, function(k) return k < word end)
  if i <= self.n and self.words[self:alpha_at(i)] == word then
    return self:alpha_at(i)
  end
  return nil
end

--- Call `fn(id)` for every word starting with `prefix`.
function Corpus:each_prefix(prefix, fn)
  local first = partition_point(self, alpha_key, function(k) return k < prefix end)
  local last = partition_point(self, alpha_key,
      function(k) return k < prefix or starts_with(k, prefix) end) - 1
  for i = first, last do fn(self:alpha_at(i)) end
  return last - first + 1
end

--- Call `fn(id)` for every word whose skeleton is exactly `skel`.
--- Words sharing a skeleton are contiguous, and the group is bounded without
--- ever walking the (potentially enormous) completion range that follows it.
function Corpus:each_skeleton_exact(skel, fn)
  local first = partition_point(self, skel_key, function(k) return k < skel end)
  local last = partition_point(self, skel_key,
      function(k) return k <= skel end) - 1
  for i = first, last do fn(self:skel_at(i)) end
  return last - first + 1
end

--- Call `fn(id)` for every word whose skeleton *extends* `skel`, i.e. the
--- completions of an abbreviation the user has not finished typing.
--- Stops after `cap` entries; short skeletons have tens of thousands of them.
function Corpus:each_skeleton_completion(skel, cap, fn)
  local first = partition_point(self, skel_key, function(k) return k <= skel end)
  local last = partition_point(self, skel_key,
      function(k) return k < skel or starts_with(k, skel) end) - 1
  if last - first + 1 > cap then last = first + cap - 1 end
  for i = first, last do fn(self:skel_at(i)) end
  return last >= first and last - first + 1 or 0
end

return Corpus
