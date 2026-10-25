-- Async access to the Rosetta Code MediaWiki API via curl + vim.system.
local parse = require("rosettascraper.parse")
local config = require("rosettascraper.config")
local store = require("rosettascraper.store")

local M = {}

local pending = {} -- url -> { callbacks }
local offline_until = 0 -- vim.uv.now() before which we skip the network
local OFFLINE_RETRY_MS = 30000

local function noop() end

--- True after a recent network failure; lookups are then served from the cache only.
function M.is_offline()
  return vim.uv.now() < offline_until
end

--- Does a curl failure mean the network is down? curl exits non-zero only on transport
--- errors (DNS, connect, TLS, timeouts). Exit 28 after --max-time ("Operation timed out")
--- means the host answered but one page rendered slowly; that must not take every other
--- lookup offline. --connect-timeout reports "Connection/Resolving timed out" instead.
function M.is_unreachable(code, stderr)
  if code == 0 then
    return false
  end
  if code == 28 and (stderr or ""):find("Operation timed out", 1, true) then
    return false
  end
  return true
end

local function urlencode(s)
  return (s:gsub("[^%w%-%._~]", function(c)
    return string.format("%%%02X", c:byte())
  end))
end

local function api_url(params)
  local parts = {}
  for k, v in pairs(params) do
    parts[#parts + 1] = k .. "=" .. urlencode(tostring(v))
  end
  table.sort(parts) -- stable URLs so in-flight dedup works
  return config.options.base_url .. "/w/api.php?" .. table.concat(parts, "&")
end

--- GET a JSON URL. Concurrent requests for the same URL share one curl process.
--- Returns a cancel function (only detaches this callback).
local function get_json(url, cb)
  local entry = { cb = cb }
  if pending[url] then
    table.insert(pending[url], entry)
    return function()
      entry.cb = nil
    end
  end
  pending[url] = { entry }
  local cmd = {
    "curl", "-sSL", "--compressed",
    "--max-time", tostring(config.options.timeout),
    "--connect-timeout", tostring(math.min(3, config.options.timeout)),
    "-A", config.options.user_agent,
    url,
  }
  vim.system(cmd, { text = true }, function(res)
    local waiters = pending[url] or {}
    pending[url] = nil
    if M.is_unreachable(res.code, res.stderr) then
      offline_until = vim.uv.now() + OFFLINE_RETRY_MS
    end
    local ok, data = false, nil
    if res.code == 0 and res.stdout and res.stdout ~= "" then
      ok, data = pcall(vim.json.decode, res.stdout)
    end
    if not ok then
      data = nil
    end
    vim.schedule(function()
      for _, w in ipairs(waiters) do
        if w.cb then
          w.cb(data, data == nil and (res.stderr ~= "" and res.stderr or "request failed") or nil)
        end
      end
    end)
  end)
  return function()
    entry.cb = nil
  end
end

local function code_key(title, lang)
  return title .. "|" .. lang -- '|' can't occur in MediaWiki titles
end

--- Titles with a cached implementation (in `lang`, or any language) starting with `query`.
function M.local_search(query, lang)
  local q = query:lower()
  local seen, titles = {}, {}
  for key, e in store.each("code") do
    local title, l = key:match("^(.*)|(.-)$")
    if title and e.v and (not lang or l == lang) and not seen[title] then
      local norm = title:lower():gsub("[_%-]", " ")
      if norm:sub(1, #q) == q then
        seen[title] = true
        titles[#titles + 1] = title
      end
    end
  end
  table.sort(titles)
  while #titles > config.options.max_results do
    table.remove(titles)
  end
  return titles
end

--- Search task titles starting with `query`. cb(titles, err)
--- Offline, falls back to titles whose `lang` implementation is cached.
function M.search(query, cb, lang)
  local key = query:lower()
  local hit = store.get("search", key)
  local function offline(err)
    local titles = M.local_search(key, lang)
    if #titles > 0 then
      return cb(titles)
    end
    cb(nil, err or "offline")
  end
  if M.is_offline() then
    offline()
    return noop
  end
  if store.is_fresh(hit) then
    cb(hit.v)
    return noop
  end
  return get_json(
    api_url({
      action = "query",
      list = "prefixsearch",
      pssearch = query,
      psnamespace = 0,
      pslimit = config.options.max_results,
      format = "json",
    }),
    function(data, err)
      if not data then
        return offline(err)
      end
      local titles = {}
      for _, r in ipairs(((data.query or {}).prefixsearch) or {}) do
        -- skip raw code pages like "Quicksort.rex"
        if not r.title:match("%.%a+$") then
          titles[#titles + 1] = r.title
        end
      end
      store.set("search", key, titles)
      cb(titles)
    end
  )
end

local function page_url(title, anchor)
  local u = config.options.base_url .. "/wiki/" .. urlencode(title:gsub(" ", "_")):gsub("%%2F", "/")
  return anchor and (u .. "#" .. urlencode(anchor:gsub(" ", "_"))) or u
end
M.page_url = page_url

--- Cached implementation of `title` in `lang` (fresh or stale), without touching the network.
--- false when the task is known to have no implementation in `lang`, nil when not cached.
function M.cached_code(title, lang)
  local hit = store.get("code", code_key(title, lang))
  if hit then
    return hit.v
  end
end

--- Fetch the implementation of `title` in Rosetta language `lang`.
--- cb(result, err) with result = { title, lang, url, blocks = { {title, lang, code} } } or nil if absent.
--- Cached results are served when fresh, or when the network is unavailable.
function M.fetch_code(title, lang, cb)
  local key = code_key(title, lang)
  local hit = store.get("code", key)
  if hit and (store.is_fresh(hit) or M.is_offline()) then
    cb(hit.v or nil)
    return noop
  end
  if M.is_offline() then
    cb(nil, "offline, and not cached yet")
    return noop
  end
  local cancelled = false
  local inner_cancel

  -- on a failed refresh, a stale cached result beats nothing
  local function fail(err)
    if hit then
      return cb(hit.v or nil)
    end
    cb(nil, M.is_offline() and "offline, and not cached yet" or err)
  end

  local function with_sections(sections, resolved_title)
    local index
    for _, s in ipairs(sections) do
      if tostring(s.level) == "2" and parse.heading_matches(s.line, lang) then
        index = s.index
        break
      end
    end
    if not index then
      store.set("code", key, false)
      return cb(nil)
    end
    inner_cancel = get_json(
      api_url({
        action = "parse",
        page = resolved_title,
        section = index,
        prop = "wikitext",
        format = "json",
        formatversion = 2,
      }),
      function(data, err)
        if cancelled then
          return
        end
        local text = data and data.parse and data.parse.wikitext
        if type(text) == "table" then
          text = text["*"]
        end
        if not text then
          return fail(err or "no wikitext")
        end
        local result = {
          title = resolved_title,
          lang = lang,
          url = page_url(resolved_title, lang),
          blocks = parse.extract_code(text),
        }
        store.set("code", key, #result.blocks > 0 and result or false)
        cb(#result.blocks > 0 and result or nil)
      end
    )
  end

  local sec = store.get("sections", title)
  if store.is_fresh(sec) then
    with_sections(sec.v.sections, sec.v.title)
  else
    inner_cancel = get_json(
      api_url({
        action = "parse",
        page = title,
        prop = "sections",
        redirects = 1,
        format = "json",
        formatversion = 2,
      }),
      function(data, err)
        if cancelled then
          return
        end
        if not (data and data.parse) then
          return fail(err or (data and data.error and data.error.info))
        end
        local v = { sections = data.parse.sections or {}, title = data.parse.title or title }
        store.set("sections", title, v)
        with_sections(v.sections, v.title)
      end
    )
  end

  return function()
    cancelled = true
    if inner_cancel then
      inner_cancel()
    end
  end
end

function M.clear_cache()
  store.clear()
end

return M
