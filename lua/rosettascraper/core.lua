-- Engine-agnostic completion logic shared by the blink.cmp and nvim-cmp adapters.
-- Items are LSP-shaped CompletionItems; the Rosetta task title lives in item.data.
local api = require("rosettascraper.api")
local parse = require("rosettascraper.parse")
local config = require("rosettascraper.config")

local M = {}

local KIND_SNIPPET = 15
local KIND_FUNCTION = 3

local timer
local cancel_inflight

--- Word immediately before the cursor (identifier chars plus '-').
function M.word_before(line, col)
  return line:sub(1, col):match("[%w_%-]+$") or ""
end

local function base_item(title, label, ident, sort, lang)
  return {
    label = label,
    filterText = ident,
    insertText = ident,
    sortText = sort,
    kind = config.options.insert == "code" and KIND_SNIPPET or KIND_FUNCTION,
    detail = "Rosetta Code · " .. lang,
    data = { rosetta_title = title, rosetta_lang = lang },
  }
end

--- Completion items for `titles`: one per code variant when the implementation is cached
--- and has several blocks, else one per task (code is then fetched on resolve).
--- Titles resolving to a page already listed (redirects) are skipped, and so are tasks
--- known to have no implementation in `lang` when accepting an item inserts code.
function M.make_items(titles, word, lang)
  local items, expanded = {}, {}
  for i, title in ipairs(titles) do
    local result = api.cached_code(title, lang)
    if result == false and config.options.insert == "code" then
      goto continue
    end
    -- redirects ("Fibonacci number" -> "Fibonacci sequence") share one page: list it once
    if result and expanded[result.title] then
      goto continue
    end
    if result then
      expanded[result.title] = true
    end
    if result and config.options.variants and #result.blocks > 1 then
      local names, nth = parse.variant_names(result.blocks)
      for j, block in ipairs(result.blocks) do
        local ident = parse.title_to_filter(title .. " " .. names[j], word)
        local item = base_item(title, title .. " › " .. names[j], ident, ("%04d%03d"):format(i, j), lang)
        item.detail = ("%s · %s (%d/%d)"):format(item.detail, names[j], j, #result.blocks)
        item.data.rosetta_block = j
        item.data.rosetta_sub = block.title
        item.data.rosetta_nth = nth[j]
        items[#items + 1] = item
      end
    else
      items[#items + 1] = base_item(title, title, parse.title_to_filter(title, word), ("%04d000"):format(i), lang)
    end
    ::continue::
  end
  return items
end

local PREFETCH_CONCURRENCY = 4

--- Fetch the code of the first `variant_prefetch` titles, a few at a time, so their
--- variants can be listed. cb() once all have answered (cache hits answer at once).
local function prefetch(titles, lang, cb)
  local n = math.min(#titles, config.options.variant_prefetch)
  if n == 0 then
    return cb()
  end
  local started, running, finished = 0, 0, 0
  local function pump()
    while running < PREFETCH_CONCURRENCY and started < n do
      started = started + 1
      running = running + 1
      api.fetch_code(titles[started], lang, function()
        running = running - 1
        finished = finished + 1
        if finished == n then
          cb()
        else
          pump()
        end
      end)
    end
  end
  pump()
end

--- Prefix search that retries with trailing words dropped when nothing matches, so
--- "fibonacci_tail" still finds "Fibonacci sequence" (and its "Tail Recursive" variant).
local function search_backoff(word, lang, cb)
  local queries = parse.query_backoff(parse.keyword_to_query(word), config.options.min_chars)
  local i, cancel, cancelled = 0, nil, false
  local function try(last_err)
    i = i + 1
    if not queries[i] then
      return cb({}, last_err)
    end
    -- a cached miss answers synchronously and recurses before api.search returns,
    -- so `cancel` may be stale: the flag is what stops a superseded chain
    cancel = api.search(queries[i], function(titles, err)
      if cancelled then
        return
      end
      if titles and #titles > 0 then
        return cb(titles)
      end
      try(err)
    end, lang)
  end
  try()
  return function()
    cancelled = true
    if cancel then
      cancel()
    end
  end
end

--- Debounced search. cb(items) is called at most once; returns a cancel function.
function M.complete(bufnr, word, cb)
  local lang = config.language_for(vim.bo[bufnr].filetype)
  if not lang or #word < config.options.min_chars then
    cb({})
    return function() end
  end
  if timer then
    timer:stop()
  end
  if cancel_inflight then
    cancel_inflight()
    cancel_inflight = nil
  end
  local done = false
  local function finish(items)
    if not done then
      done = true
      cb(items)
    end
  end
  timer = timer or vim.uv.new_timer()
  timer:start(config.options.debounce_ms, 0, vim.schedule_wrap(function()
    if done then
      return
    end
    cancel_inflight = search_backoff(word, lang, function(titles)
      local function build()
        finish(M.make_items(titles, word, lang))
      end
      if not config.options.variants then
        return build()
      end
      -- prefetches are not cancelled when the user types on: they fill the cache
      -- the next keystroke's query reads from
      vim.defer_fn(build, config.options.variant_wait_ms)
      prefetch(titles, lang, build)
    end)
  end))
  return function()
    done = true
  end
end

local function fence_lang(block)
  return block.lang or vim.bo.filetype
end

--- Markdown documentation for a fetched implementation.
--- `block`: render only that variant instead of the first `doc_max_blocks` blocks.
function M.render_doc(result, block)
  local out = { "# " .. result.title, "", "_" .. result.lang .. "_ · " .. result.url, "" }
  for i, b in ipairs(block and { block } or result.blocks) do
    if i > config.options.doc_max_blocks then
      out[#out + 1] = string.format("_… %d more variant(s) on the page_", #result.blocks - i + 1)
      break
    end
    if b.title then
      out[#out + 1] = "## " .. b.title
    end
    out[#out + 1] = "```" .. fence_lang(b)
    out[#out + 1] = b.code
    out[#out + 1] = "```"
    out[#out + 1] = ""
  end
  return table.concat(out, "\n")
end

--- Fill in documentation for an item. cb(item)
function M.resolve(item, cb)
  local d = item.data or {}
  if not d.rosetta_title then
    return cb(item)
  end
  api.fetch_code(d.rosetta_title, d.rosetta_lang, function(result, err)
    if result then
      local block = d.rosetta_block and parse.pick_block(result.blocks, d.rosetta_block, d.rosetta_sub, d.rosetta_nth)
      item.documentation = { kind = "markdown", value = M.render_doc(result, block) }
    elseif err then
      item.documentation = {
        kind = "markdown",
        value = string.format("Couldn't load **%s** (%s).\n\n%s", d.rosetta_title, err, api.page_url(d.rosetta_title)),
      }
    else
      item.documentation = {
        kind = "markdown",
        value = string.format("No %s implementation of **%s** on Rosetta Code yet.\n\n%s",
          d.rosetta_lang, d.rosetta_title, api.page_url(d.rosetta_title)),
      }
    end
    cb(item)
  end)
end

--- Replace text [col_start, col_end) on `row` (0-based) with `code`, re-indented
--- to match the line. Must be called from the main loop.
function M.put_code(bufnr, row, col_start, col_end, code)
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1] or ""
  local indent = line:match("^%s*")
  local lines = vim.split(code, "\n", { plain = true })
  for i = 2, #lines do
    if lines[i] ~= "" then
      lines[i] = indent .. lines[i]
    end
  end
  vim.api.nvim_buf_set_text(bufnr, row, col_start, row, col_end, lines)
end

--- After an item was accepted: swap the inserted identifier for the code.
--- Runs async; the identifier stays if no implementation exists.
function M.execute(item, done)
  done = done or function() end
  local d = item.data or {}
  if config.options.insert ~= "code" or not d.rosetta_title then
    return done()
  end
  local bufnr = vim.api.nvim_get_current_buf()
  local inserted = item.insertText or item.label
  local cur = vim.api.nvim_win_get_cursor(0)
  local row, col = cur[1] - 1, cur[2]
  local line = vim.api.nvim_get_current_line()
  -- the cursor sits after the word in insert mode, on its last char in normal mode
  local start
  for _, end_col in ipairs({ col, col + 1 }) do
    local s = end_col - #inserted
    if s >= 0 and line:sub(s + 1, end_col) == inserted then
      start = s
      break
    end
  end
  if not start then
    return done()
  end
  -- an extmark tracks the inserted word in case the user keeps typing while we fetch
  local ns = vim.api.nvim_create_namespace("rosettascraper")
  local mark = vim.api.nvim_buf_set_extmark(bufnr, ns, row, start, {
    end_row = row,
    end_col = start + #inserted,
    right_gravity = true,
    end_right_gravity = false,
  })
  api.fetch_code(d.rosetta_title, d.rosetta_lang, function(result, err)
    local pos = vim.api.nvim_buf_is_valid(bufnr)
      and vim.api.nvim_buf_get_extmark_by_id(bufnr, ns, mark, { details = true })
    if pos and pos[1] then
      vim.api.nvim_buf_del_extmark(bufnr, ns, mark)
      local text = vim.api.nvim_buf_get_text(bufnr, pos[1], pos[2], pos[3].end_row, pos[3].end_col, {})
      if result and #text == 1 and text[1] == inserted then
        local block = parse.pick_block(result.blocks, d.rosetta_block, d.rosetta_sub, d.rosetta_nth)
        M.put_code(bufnr, pos[1], pos[2], pos[3].end_col, block.code)
      elseif not result then
        vim.notify(err and ("rosettascraper: couldn't load " .. d.rosetta_title .. " (" .. err .. ")")
          or ("rosettascraper: no " .. d.rosetta_lang .. " implementation of " .. d.rosetta_title),
          vim.log.levels.INFO)
      end
    end
    done()
  end)
end

return M
