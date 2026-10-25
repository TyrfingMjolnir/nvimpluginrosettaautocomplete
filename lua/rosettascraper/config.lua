local M = {}

M.defaults = {
  base_url = "https://rosettacode.org",
  -- minimum identifier length before Rosetta Code is queried
  min_chars = 4,
  -- max titles requested from the prefix search
  max_results = 20,
  -- ms to wait after the last keystroke before hitting the network
  debounce_ms = 250,
  -- curl --max-time, seconds
  timeout = 10,
  user_agent = "nvim-rosettascraper (+https://github.com/)",
  -- "code": accepting a completion replaces the word with the first code block
  -- "name": only insert the task name as an identifier
  insert = "code",
  -- filetype -> Rosetta Code language name, merged over parse.languages
  languages = {},
  -- filetypes where the source is active; nil = every filetype with a known language
  filetypes = nil,
  -- max code blocks shown in the documentation popup
  doc_max_blocks = 3,
  -- one menu item per implementation variant ("Fibonacci sequence › Tail Recursive")
  -- instead of one per task; needs the code, so it is fetched while the menu is built
  variants = true,
  -- how many search hits get their code fetched per query (cached ones always expand)
  variant_prefetch = 8,
  -- ms the menu waits for that fetch; later arrivals show on the next keystroke
  variant_wait_ms = 800,
  -- lookups are saved here and reused offline; false keeps the cache in memory only
  cache_path = vim.fn.stdpath("data") .. "/rosettascraper/cache.json",
  -- cached entries older than this are refreshed when online (stale ones still serve offline)
  cache_ttl_days = 30,
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

--- Rosetta language name for a filetype, or nil.
function M.language_for(ft)
  if M.options.filetypes and not vim.tbl_contains(M.options.filetypes, ft) then
    return nil
  end
  return M.options.languages[ft] or require("rosettascraper.parse").languages[ft]
end

return M
