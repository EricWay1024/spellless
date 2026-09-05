-- The baseline the design exists to avoid: weighted edit distance against
-- every word in the dictionary, per keystroke.
--
--     lua bench/naive.lua
--
-- Quoted in EVALUATION.md § Latency.  Run it after changing distance.lua to
-- check the comparison is still honest.

local root = arg[0]:match("^(.*)/bench/naive%.lua$") or "."
package.path = root .. "/rime/lua/?.lua;" .. package.path

local Corpus = require("spellless.corpus")
local distance = require("spellless.distance")
local generate = require("spellless.generate")
local config = require("spellless.config")

local corpus = assert(Corpus.load(root .. "/generated"))
local cfg = config.build{}
local profile = generate.TYPO_PROFILE
local queries = { "recommned", "mathe", "recieve", "theorme", "seperate" }

local t, hits = os.clock(), 0
for _, q in ipairs(queries) do
  for id = 1, corpus.n do
    if distance.distance(q, corpus.words[id], cfg.typo_budget, profile) then
      hits = hits + 1
    end
  end
end
print(("naive full scan over %d words: %.1f ms per query (%d within budget)")
      :format(corpus.n, (os.clock() - t) / #queries * 1000, hits))
