-- nvim-cmp source, registered as "rosetta" by rosettascraper.setup() when cmp is installed.
local core = require("rosettascraper.core")
local config = require("rosettascraper.config")

local source = {}

function source.new()
  return setmetatable({}, { __index = source })
end

function source:is_available()
  return config.language_for(vim.bo.filetype) ~= nil
end

function source:get_debug_name()
  return "rosetta"
end

function source:get_keyword_pattern()
  return [[\k\+]]
end

function source:complete(params, callback)
  local ctx = params.context
  local word = core.word_before(ctx.cursor_before_line, #ctx.cursor_before_line)
  core.complete(ctx.bufnr, word, function(items)
    callback({ items = items, isIncomplete = true })
  end)
end

function source:resolve(item, callback)
  core.resolve(item, callback)
end

function source:execute(item, callback)
  core.execute(item, callback)
end

return source
