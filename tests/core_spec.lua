-- Run from the repo root: nvim --headless -l tests/core_spec.lua
-- Exercises core.lua (menu items, variants, resolve, execute) with the network stubbed out.
vim.opt.rtp:prepend(".")

local failures = 0
local function eq(got, want, what)
  if got ~= want then
    failures = failures + 1
    print(("FAIL %s\n  got:  %s\n  want: %s"):format(what, vim.inspect(got), vim.inspect(want)))
  end
end

-- is_unreachable lives in the real api module; check it before the stub replaces it.
local real_api = require("rosettascraper.api")
eq(real_api.is_unreachable(0, ""), false, "curl ok is reachable")
eq(real_api.is_unreachable(28, "curl: (28) Operation timed out after 10000 milliseconds with 0 bytes received"),
  false, "slow page (--max-time) is not offline")
eq(real_api.is_unreachable(28, "curl: (28) Resolving timed out after 3000 milliseconds"), true, "DNS timeout is offline")
eq(real_api.is_unreachable(28, "curl: (28) Connection timed out after 3001 milliseconds"), true, "connect timeout is offline")
eq(real_api.is_unreachable(6, "curl: (6) Could not resolve host"), true, "DNS failure is offline")
package.loaded["rosettascraper.api"] = nil

local config = require("rosettascraper.config")
config.setup({ cache_path = false, debounce_ms = 0, variant_wait_ms = 300 })

-- Stub api: an in-memory "cache" plus scripted search and fetch behaviour.
local FIB = {
  title = "Fibonacci sequence",
  lang = "Lua",
  url = "https://rosettacode.org/wiki/Fibonacci_sequence#Lua",
  blocks = {
    { title = "Recursive", code = "function fibs(n) return n < 2 and n or fibs(n-1) + fibs(n-2) end" },
    { title = "Tail Recursive", code = "function a(n,u,s) if n<2 then return u+s end\n  return a(n-1,u+s,u)\nend" },
    { title = "Iterative", code = "function ifibs(n) end" },
  },
}
local api = {
  cache = {},
  searches = {},
  fetches = {},
  never_answer = {},
  search_results = {},
}
function api.cached_code(title, lang)
  return api.cache[title .. "|" .. lang]
end
function api.search(query, cb)
  table.insert(api.searches, query)
  local titles = api.search_results[query] or {}
  vim.schedule(function()
    cb(titles)
  end)
  return function() end
end
function api.fetch_code(title, lang, cb)
  table.insert(api.fetches, title)
  local key = title .. "|" .. lang
  if api.cache[key] ~= nil then
    cb(api.cache[key] or nil)
    return function() end
  end
  if api.never_answer[title] then
    return function() end
  end
  vim.defer_fn(function()
    -- every Fibonacci redirect resolves to the same page
    api.cache[key] = title:match("^Fibonacci [ns]") and FIB or false
    cb(api.cache[key] or nil)
  end, 20)
  return function() end
end
function api.page_url(title)
  return "https://rosettacode.org/wiki/" .. title
end
package.loaded["rosettascraper.api"] = api

local core = require("rosettascraper.core")

local function reset()
  api.cache, api.searches, api.fetches, api.never_answer = {}, {}, {}, {}
end

local function by_label(items)
  local m = {}
  for _, it in ipairs(items) do
    m[it.label] = it
  end
  return m
end

-- 1. make_items: cached multi-block task expands into variants, redirects are listed once
reset()
api.cache["Fibonacci number|Lua"] = FIB
api.cache["Fibonacci numbers|Lua"] = FIB
api.cache["Fibonacci sequence|Lua"] = FIB
local items = core.make_items({ "Fibonacci heap", "Fibonacci number", "Fibonacci numbers", "Fibonacci sequence" },
  "fibonacci_t", "Lua")
eq(#items, 4, "heap task + 3 variants, duplicates via redirect dropped")
local m = by_label(items)
eq(m["Fibonacci heap"] ~= nil, true, "uncached task stays a single item")
local tail = m["Fibonacci number › Tail Recursive"]
eq(tail ~= nil, true, "tail recursive variant listed")
eq(tail and tail.filterText, "fibonacci_number_tail_recursive", "variant filterText follows typed style")
eq(tail and tail.insertText, tail and tail.filterText, "insertText equals filterText")
eq(tail and tail.data.rosetta_title, "Fibonacci number", "variant fetches the task page, not its label")
eq(tail and tail.data.rosetta_block, 2, "variant records block index")
eq(tail and tail.data.rosetta_sub, "Tail Recursive", "variant records subheading")
eq(tail and tail.detail, "Rosetta Code · Lua · Tail Recursive (2/3)", "variant detail")
eq(m["Fibonacci sequence › Recursive"], nil, "redirect target not repeated")
local sorted = vim.deepcopy(items)
table.sort(sorted, function(a, b)
  return a.sortText < b.sortText
end)
eq(sorted[1].label, "Fibonacci heap", "search order kept")
eq(sorted[3].label, "Fibonacci number › Tail Recursive", "variants in page order")

-- 2. variants = false keeps one item per task
config.options.variants = false
eq(#core.make_items({ "Fibonacci number" }, "fibo", "Lua"), 1, "variants off: one item per task")
config.options.variants = true

-- a cached single-block task stays one item
api.cache["Fibonacci word|Lua"] = { title = "Fibonacci word", lang = "Lua", url = "", blocks = { { code = "x" } } }
eq(#core.make_items({ "Fibonacci word" }, "fibo", "Lua"), 1, "single block: one item")

-- 3. complete(): backoff to a shorter query, prefetch, then list variants
reset()
api.search_results = {
  ["fibonacci"] = { "Fibonacci heap", "Fibonacci number", "Fibonacci sequence" },
}
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "lua"
local got
core.complete(buf, "fibonacci_tail", function(its)
  got = its
end)
vim.wait(2000, function()
  return got ~= nil
end)
eq(table.concat(api.searches, ","), "fibonacci tail,fibonacci", "backoff dropped the unmatched word")
eq(got and by_label(got)["Fibonacci number › Tail Recursive"] ~= nil, true, "complete lists tail recursive variant")
eq(got and #got, 3, "complete: 3 variants, heap (no Lua implementation) hidden")

-- 4. a page that never answers: menu still shows after variant_wait_ms, unexpanded
reset()
api.never_answer["Fibonacci heap"] = true
api.search_results = { ["fibonacci"] = { "Fibonacci heap" } }
got = nil
local t0 = vim.uv.now()
core.complete(buf, "fibonacci", function(its)
  got = its
end)
vim.wait(2000, function()
  return got ~= nil
end)
local waited = vim.uv.now() - t0
eq(got and #got, 1, "slow page: task item shown")
eq(waited >= 250 and waited < 1500, true, "slow page: waited about variant_wait_ms (" .. waited .. " ms)")

-- 5. prefetch stops at variant_prefetch titles
reset()
config.options.variant_prefetch = 2
api.search_results = { ["fibonacci"] = { "A1", "A2", "A3", "A4" } }
got = nil
core.complete(buf, "fibonacci", function(its)
  got = its
end)
vim.wait(2000, function()
  return got ~= nil
end)
eq(#api.fetches, 2, "prefetch limited to variant_prefetch")
config.options.variant_prefetch = 8

-- 5b. a superseded backoff chain stays dead even when the first search answers synchronously
-- (a cached empty result): its fallback search must not call back or start a prefetch
reset()
local real_search = api.search
local late = {}
api.search = function(query, cb)
  table.insert(api.searches, query)
  if query == "fibonacci tail" then
    cb({}) -- synchronous cache hit, no titles
    return function() end
  end
  local pending = { cb = cb }
  table.insert(late, pending)
  return function()
    pending.cb = nil
  end
end
local old_fired = false
local cancel_old = core.complete(buf, "fibonacci_tail", function()
  old_fired = true
end)
vim.wait(100, function()
  return #late > 0
end)
cancel_old()
core.complete(buf, "fibonacci_x", function() end) -- the user typed on
-- the old fallback search ("fibonacci") now answers; a lost cancel lets it through
for _, p in ipairs(late) do
  if p.cb then
    p.cb({ "Fibonacci sequence" })
  end
end
vim.wait(400, function()
  return false
end)
eq(old_fired, false, "superseded completion never calls back")
eq(#api.fetches, 0, "superseded completion starts no prefetch")
api.search = real_search

-- single-block redirects are listed once too
reset()
local WORD = { title = "Fibonacci word", lang = "Lua", url = "", blocks = { { code = "w" } } }
api.cache["Fibonacci words|Lua"] = WORD
api.cache["Fibonacci word|Lua"] = WORD
eq(#core.make_items({ "Fibonacci words", "Fibonacci word" }, "fibo", "Lua"), 1, "single-block redirect deduped")

-- tasks known to have no implementation are hidden in code mode, kept in name mode
reset()
api.cache["Fibonacci heap|Lua"] = false
api.cache["Fibonacci number|Lua"] = FIB
local hidden = by_label(core.make_items({ "Fibonacci heap", "Fibonacci number", "Fibonacci word" }, "fibo", "Lua"))
eq(hidden["Fibonacci heap"], nil, "no-implementation task hidden")
eq(hidden["Fibonacci word"] ~= nil, true, "uncached task still shown")
eq(hidden["Fibonacci number › Tail Recursive"] ~= nil, true, "implemented task still expanded")
config.options.insert = "name"
eq(by_label(core.make_items({ "Fibonacci heap" }, "fibo", "Lua"))["Fibonacci heap"] ~= nil, true,
  "insert=name keeps no-implementation task")
config.options.insert = "code"

-- 6. resolve a variant: the docs show only that block
reset()
api.cache["Fibonacci number|Lua"] = FIB
local resolved
core.resolve(vim.deepcopy(tail), function(it)
  resolved = it
end)
local doc = resolved and resolved.documentation.value or ""
eq(doc:find("function a(n,u,s)", 1, true) ~= nil, true, "doc has tail recursive code")
eq(doc:find("function ifibs", 1, true), nil, "doc omits other variants")

-- 7. execute a variant: the inserted identifier becomes that block's code
local win_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_buf_set_lines(win_buf, 0, -1, false, { "  local x = 1", "  " .. tail.insertText })
vim.api.nvim_win_set_cursor(0, { 2, #("  " .. tail.insertText) - 1 }) -- normal mode: on the last char
local executed = false
core.execute(vim.deepcopy(tail), function()
  executed = true
end)
vim.wait(1000, function()
  return executed
end)
local lines = vim.api.nvim_buf_get_lines(win_buf, 0, -1, false)
eq(lines[2], "  function a(n,u,s) if n<2 then return u+s end", "execute inserts the chosen variant")
eq(lines[3], "    return a(n-1,u+s,u)", "execute re-indents following lines")

if failures > 0 then
  print(failures .. " failure(s)")
  vim.cmd("cquit 1")
end
print("all core tests passed")
