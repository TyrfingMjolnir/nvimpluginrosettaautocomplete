-- Run from the repo root: lua tests/parse_spec.lua [optional-wikitext-file]
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path
local parse = require("rosettascraper.parse")

local failures = 0
local function eq(got, want, what)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, tostring(got), tostring(want)))
  end
end

eq(parse.keyword_to_query("binary_search"), "binary search", "snake_case query")
eq(parse.keyword_to_query("binarySearch"), "binary search", "camelCase query")
eq(parse.keyword_to_query("quick-sort"), "quick sort", "kebab query")
eq(parse.keyword_to_query("fibon"), "fibon", "plain query")

eq(parse.title_to_filter("Binary search", "binary_s"), "binary_search", "snake filter")
eq(parse.title_to_filter("Binary search", "binarySe"), "binarySearch", "camel filter")
eq(parse.title_to_filter("Sorting algorithms/Quicksort", "sorting"), "sortingalgorithmsquicksort", "plain filter")

eq(parse.heading_matches("Lua", "Lua"), true, "heading exact")
eq(parse.heading_matches("C#", "C sharp"), true, "heading alias")
eq(parse.heading_matches("Luck", "Lua"), false, "heading mismatch")

local fixture = [[
=={{header|Lua}}==
===Recursive===
<syntaxhighlight lang="lua">
function fibs(n)
  return n < 2 and n or fibs(n - 1) + fibs(n - 2)
end
</syntaxhighlight>
Some prose with x = y in it.

===Iterative===
<lang lua>local a, b = 0, 1</lang>
<pre>
a &lt; b &amp;&amp; c
</pre>
]]
local blocks = parse.extract_code(fixture)
eq(#blocks, 2, "block count (pre ignored)")
eq(blocks[1].title, "Recursive", "block 1 subheading")
eq(blocks[1].lang, "lua", "block 1 lang")
eq(blocks[1].code:sub(1, 15), "function fibs(n", "block 1 code")
eq(blocks[2].title, "Iterative", "block 2 subheading")
eq(blocks[2].lang, "lua", "block 2 <lang> tag")
eq(blocks[2].code, "local a, b = 0, 1", "block 2 code")
eq(parse.strip_markup("[[Foo|bar]] &lt;x&gt;"), "bar <x>", "strip markup")
eq(parse.strip_markup("L&Ouml;VE"), "LÖVE", "named latin entity")
eq(parse.strip_markup("&#955; &#x3BB; &#8212; &#128512;"), "λ λ — 😀", "numeric entities to UTF-8")
eq(parse.strip_markup("&bogus; &#xZZ;"), "&bogus; &#xZZ;", "unknown entities kept")

-- query backoff: drop trailing words, never below min_len (the full query always stays)
local qb = parse.query_backoff("fibonacci tail recursive", 4)
eq(#qb, 3, "backoff count")
eq(qb[1], "fibonacci tail recursive", "backoff full first")
eq(qb[2], "fibonacci tail", "backoff drops one word")
eq(qb[3], "fibonacci", "backoff single word")
eq(#parse.query_backoff("fib tail", 4), 1, "backoff respects min_len")
eq(#parse.query_backoff("", 4), 0, "backoff empty query")

-- variant names: subheading, numbered duplicates, #i when untitled
local vb = { { title = "Recursive" }, { title = "Tail Recursive" }, { title = "Recursive" }, {} }
local names = parse.variant_names(vb)
eq(names[1], "Recursive (1)", "variant dup 1")
eq(names[2], "Tail Recursive", "variant unique")
eq(names[3], "Recursive (2)", "variant dup 2")
eq(names[4], "#4", "variant untitled")
eq(parse.variant_names({ { title = "L&Ouml;VE" } })[1], "LÖVE", "variant name decodes cached entities")
local _, nth = parse.variant_names(vb)
eq(nth[1], 1, "nth first Recursive")
eq(nth[3], 2, "nth second Recursive")
eq(nth[4], nil, "nth untitled")

-- pick_block: index when it still matches, else re-find by subheading, else fall back
local pb = { { title = "Recursive", code = "r" }, { title = "Tail Recursive", code = "t" }, { title = "Iterative", code = "i" } }
eq(parse.pick_block(pb).code, "r", "pick default first")
eq(parse.pick_block(pb, 2, "Tail Recursive").code, "t", "pick by index")
eq(parse.pick_block(pb, 1, "Iterative").code, "i", "pick re-finds moved subheading")
eq(parse.pick_block(pb, 3, "Gone").code, "i", "pick falls back to index")
eq(parse.pick_block(pb, 9, "Gone").code, "r", "pick falls back to first")
eq(parse.pick_block(pb, 9, nil).code, "r", "pick untitled out of range")
-- duplicate subheadings: after a shift, the nth occurrence is re-found, not the first
local dup = { { title = "Intro", code = "x" }, { title = "Gen", code = "g1" }, { title = "Gen", code = "g2" } }
eq(parse.pick_block(dup, 2, "Gen", 2).code, "g2", "pick re-finds nth duplicate after shift")
eq(parse.pick_block(dup, 1, "Gen", 5).code, "g1", "pick nth missing falls back to first match")

-- Optional: a real section dumped from the API
if arg[1] then
  local f = assert(io.open(arg[1]))
  local real = parse.extract_code(f:read("a"))
  f:close()
  print(("real section: %d blocks"):format(#real))
  for i = 1, math.min(#real, 3) do
    print(("  [%s] %s"):format(real[i].title or "-", real[i].code:match("[^\n]*")))
  end
  eq(#real > 0, true, "real section has code")
end

if failures > 0 then
  print(failures .. " failure(s)")
  os.exit(1)
end
print("all parse tests passed")
