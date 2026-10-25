-- blink.cmp source.  sources.providers.rosetta = { name = "Rosetta", module = "rosettascraper.blink" }
local core = require("rosettascraper.core")
local config = require("rosettascraper.config")

local source = {}

function source.new(opts)
  if opts and next(opts) then
    config.setup(vim.tbl_deep_extend("force", config.options, opts))
  end
  return setmetatable({}, { __index = source })
end

function source:enabled()
  return config.language_for(vim.bo.filetype) ~= nil
end

function source:get_completions(ctx, callback)
  local word = core.word_before(ctx.line, ctx.cursor[2])
  return core.complete(ctx.bufnr, word, function(items)
    local row = ctx.cursor[1] - 1
    for _, item in ipairs(items) do
      item.textEdit = {
        newText = item.insertText,
        range = {
          start = { line = row, character = ctx.cursor[2] - #word },
          ["end"] = { line = row, character = ctx.cursor[2] },
        },
      }
    end
    -- results depend on the typed prefix, so ask blink to re-query as the user types
    callback({ items = items, is_incomplete_forward = true, is_incomplete_backward = true })
  end)
end

function source:resolve(item, callback)
  core.resolve(item, callback)
end

function source:execute(_, item, callback, default_implementation)
  default_implementation()
  core.execute(item, callback)
end

return source
