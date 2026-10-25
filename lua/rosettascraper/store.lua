-- Persistent JSON cache, so lookups survive restarts and work offline.
-- Buckets: search (query -> titles), sections (title -> page sections),
-- code (title|lang -> result | false). Entries are { t = os.time(), v = value }.
local config = require("rosettascraper.config")

local M = {}

local VERSION = 1
local data -- loaded lazily on first access
local dirty = false
local save_scheduled = false

local function empty()
  return { version = VERSION, search = {}, sections = {}, code = {} }
end

local function path()
  return config.options.cache_path
end

local function read_file(p)
  local f = p and io.open(p, "r")
  if not f then
    return nil
  end
  local s = f:read("*a")
  f:close()
  local ok, d = pcall(vim.json.decode, s)
  if ok and type(d) == "table" and d.version == VERSION then
    for _, bucket in ipairs({ "search", "sections", "code" }) do
      d[bucket] = type(d[bucket]) == "table" and d[bucket] or {}
    end
    return d
  end
end

local function load()
  if not data then
    data = read_file(path()) or empty()
  end
  return data
end

--- Write to disk now. Entries another Neovim wrote meanwhile are merged in, newest wins.
function M.flush()
  local p = path()
  if not (p and data and dirty) then
    return
  end
  local disk = read_file(p)
  if disk then
    for _, bucket in ipairs({ "search", "sections", "code" }) do
      for k, e in pairs(disk[bucket]) do
        local mine = data[bucket][k]
        if type(e) == "table" and (not mine or (e.t or 0) > (mine.t or 0)) then
          data[bucket][k] = e
        end
      end
    end
  end
  vim.fn.mkdir(vim.fn.fnamemodify(p, ":h"), "p")
  local tmp = p .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then
    return
  end
  f:write(vim.json.encode(data))
  f:close()
  os.rename(tmp, p)
  dirty = false
end

local function schedule_save()
  dirty = true
  if save_scheduled or not path() then
    return
  end
  save_scheduled = true
  vim.defer_fn(function()
    save_scheduled = false
    M.flush()
  end, 2000)
end

--- Cached entry { t, v } or nil.
function M.get(bucket, key)
  return load()[bucket][key]
end

function M.set(bucket, key, value)
  load()[bucket][key] = { t = os.time(), v = value }
  schedule_save()
end

--- Iterate (key, entry) over a bucket.
function M.each(bucket)
  return pairs(load()[bucket])
end

function M.is_fresh(entry)
  return entry ~= nil and os.time() - (entry.t or 0) < config.options.cache_ttl_days * 86400
end

--- Forget everything, in memory and on disk.
function M.clear()
  data, dirty = empty(), false
  if path() then
    os.remove(path())
  end
end

vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("rosettascraper_store", { clear = true }),
  callback = function()
    M.flush()
  end,
})

return M
