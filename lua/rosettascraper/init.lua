local config = require("rosettascraper.config")

local M = {}

function M.setup(opts)
  config.setup(opts)
  local ok, cmp = pcall(require, "cmp")
  if ok and cmp.register_source then
    cmp.register_source("rosetta", require("rosettascraper.cmp").new())
  end
end

--- :Rosetta [query] — pick a task and insert its implementation at the cursor.
function M.pick(query)
  local api = require("rosettascraper.api")
  local core = require("rosettascraper.core")
  local lang = config.language_for(vim.bo.filetype)
  if not lang then
    return vim.notify("rosettascraper: no Rosetta language for filetype '" .. vim.bo.filetype .. "'",
      vim.log.levels.WARN)
  end
  if not query or query == "" then
    query = vim.fn.expand("<cword>")
  end
  local bufnr, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  api.search(require("rosettascraper.parse").keyword_to_query(query), function(titles, err)
    if not titles or #titles == 0 then
      return vim.notify("rosettascraper: no tasks match '" .. query .. "'" .. (err and (" (" .. err .. ")") or ""),
        vim.log.levels.WARN)
    end
    vim.ui.select(titles, { prompt = "Rosetta Code (" .. lang .. ")" }, function(title)
      if not title then
        return
      end
      api.fetch_code(title, lang, function(result, err)
        if not result then
          return vim.notify(err and ("rosettascraper: couldn't load " .. title .. " (" .. err .. ")")
            or ("rosettascraper: no " .. lang .. " implementation of " .. title), vim.log.levels.WARN)
        end
        local function put(code)
          if not vim.api.nvim_win_is_valid(win) then
            return
          end
          local row = vim.api.nvim_win_get_cursor(win)[1]
          vim.api.nvim_buf_set_lines(bufnr, row, row, false, { "" })
          core.put_code(bufnr, row, 0, 0, code)
        end
        if #result.blocks == 1 then
          return put(result.blocks[1].code)
        end
        vim.ui.select(result.blocks, {
          prompt = title .. " — variant",
          format_item = function(b)
            local first = b.code:match("[^\n]*")
            return (b.title and (b.title .. ": ") or "") .. first
          end,
        }, function(b)
          if b then
            put(b.code)
          end
        end)
      end)
    end)
  end, lang)
end

return M
