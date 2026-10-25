-- Pure-Lua helpers (no vim.* usage) so they can be unit tested with plain `lua`.
local M = {}

-- Neovim filetype -> Rosetta Code language header name.
M.languages = {
  ada = "Ada",
  awk = "AWK",
  c = "C",
  clojure = "Clojure",
  cobol = "COBOL",
  coffee = "CoffeeScript",
  cpp = "C++",
  crystal = "Crystal",
  cs = "C sharp",
  d = "D",
  dart = "Dart",
  elixir = "Elixir",
  elm = "Elm",
  erlang = "Erlang",
  fennel = "Fennel",
  fortran = "Fortran",
  fsharp = "F Sharp",
  go = "Go",
  groovy = "Groovy",
  haskell = "Haskell",
  java = "Java",
  javascript = "JavaScript",
  javascriptreact = "JavaScript",
  julia = "Julia",
  kotlin = "Kotlin",
  lisp = "Common Lisp",
  lua = "Lua",
  matlab = "MATLAB",
  nim = "Nim",
  ocaml = "OCaml",
  pascal = "Pascal",
  perl = "Perl",
  php = "PHP",
  powershell = "PowerShell",
  ps1 = "PowerShell",
  prolog = "Prolog",
  python = "Python",
  r = "R",
  racket = "Racket",
  ruby = "Ruby",
  rust = "Rust",
  scala = "Scala",
  scheme = "Scheme",
  sh = "UNIX Shell",
  bash = "UNIX Shell",
  zsh = "Zsh",
  sql = "SQL",
  swift = "Swift",
  tcl = "Tcl",
  typescript = "TypeScript",
  typescriptreact = "TypeScript",
  vb = "Visual Basic .NET",
  vim = "Vim Script",
  zig = "Zig",
}

-- Alternative header spellings seen on Rosetta Code.
M.aliases = {
  ["C sharp"] = { "C sharp", "C#" },
  ["F Sharp"] = { "F Sharp", "F#" },
  ["UNIX Shell"] = { "UNIX Shell", "Bash" },
}

local function norm(s)
  return (s:lower():gsub("[%s_]+", " "):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Does a section heading (as returned by the parse API "line" field) name `lang`?
function M.heading_matches(line, lang)
  local wanted = M.aliases[lang] or { lang }
  local l = norm(line:gsub("<[^>]->", ""))
  for _, w in ipairs(wanted) do
    if l == norm(w) then
      return true
    end
  end
  return false
end

--- Turn an identifier the user is typing into a Rosetta task title prefix.
--- "binary_search" / "binarySearch" / "binary-search" -> "binary search".
--- Lowercased because MediaWiki prefix search only folds case on the first letter.
function M.keyword_to_query(word)
  local q = word:gsub("(%l)(%u)", "%1 %2"):gsub("[_%-]+", " "):lower()
  return (q:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Fallback queries for an identifier that names no task: drop trailing words
--- until something may match. "fibonacci tail recursive" -> { that, "fibonacci tail", "fibonacci" }.
--- The completion engine's fuzzy matcher then narrows the broader results back down.
function M.query_backoff(query, min_len)
  local words = {}
  for w in query:gmatch("%S+") do
    words[#words + 1] = w
  end
  local out = {}
  for n = #words, 1, -1 do
    local q = table.concat(words, " ", 1, n)
    if n == #words or #q >= (min_len or 1) then
      out[#out + 1] = q
    end
  end
  return out
end

--- Render a task title in the identifier style the user is typing, so the
--- completion engine's fuzzy matcher keeps it. "Binary search" + "binary_s" -> "binary_search"
function M.title_to_filter(title, word)
  local parts = {}
  for p in title:gmatch("[%w]+") do
    parts[#parts + 1] = p
  end
  if word:find("_") then
    return table.concat(parts, "_"):lower()
  elseif word:find("%-") then
    return table.concat(parts, "-"):lower()
  elseif word:find("%l%u") then
    for i, p in ipairs(parts) do
      parts[i] = (i == 1) and p:lower() or (p:sub(1, 1):upper() .. p:sub(2):lower())
    end
    return table.concat(parts)
  end
  return table.concat(parts):lower()
end

local entities = { lt = "<", gt = ">", amp = "&", quot = '"', apos = "'", nbsp = " " }
-- named entities seen in Rosetta Code headings, as code points
local named_cp = {
  Auml = 196, Ouml = 214, Uuml = 220, auml = 228, ouml = 246, uuml = 252, szlig = 223,
  Aring = 197, aring = 229, AElig = 198, aelig = 230, Oslash = 216, oslash = 248,
  eacute = 233, egrave = 232, ecirc = 234, aacute = 225, agrave = 224, iacute = 237,
  oacute = 243, uacute = 250, ntilde = 241, ccedil = 231, ndash = 8211, mdash = 8212,
  lsquo = 8216, rsquo = 8217, ldquo = 8220, rdquo = 8221, hellip = 8230, times = 215,
  copy = 169, reg = 174, deg = 176, middot = 183, lambda = 955, pi = 960,
}

-- UTF-8 encoding of a code point (LuaJIT has no utf8 library).
local function utf8_char(n)
  if n < 0x80 then
    return string.char(n)
  elseif n < 0x800 then
    return string.char(0xC0 + math.floor(n / 0x40), 0x80 + n % 0x40)
  elseif n < 0x10000 then
    return string.char(0xE0 + math.floor(n / 0x1000), 0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  elseif n < 0x110000 then
    return string.char(0xF0 + math.floor(n / 0x40000), 0x80 + math.floor(n / 0x1000) % 0x40,
      0x80 + math.floor(n / 0x40) % 0x40, 0x80 + n % 0x40)
  end
end

local function decode_entities(s)
  return (s:gsub("&(#?)(%w+);", function(hash, name)
    if hash == "#" then
      local n = name:match("^[xX](%x+)$")
      n = n and tonumber(n, 16) or tonumber(name)
      return n and utf8_char(n) or nil
    end
    return entities[name] or (named_cp[name] and utf8_char(named_cp[name]))
  end))
end

--- Extract code blocks from a wikitext section. <pre> is ignored: on Rosetta Code
--- it holds program output ({{out}}) or inline notes, not implementations.
--- Returns a list of { title = subheading-or-nil, lang = "lua"|nil, code = "..." }.
function M.extract_code(wikitext)
  local blocks = {}
  local pos = 1
  local current_sub
  while true do
    -- find the next opening tag of any supported kind
    local best_s, best_e, best_tag, best_attrs
    for _, tag in ipairs({ "syntaxhighlight", "lang", "source" }) do
      local s, e, attrs = wikitext:find("<" .. tag .. "([^>]*)>", pos)
      if s and (not best_s or s < best_s) then
        best_s, best_e, best_tag, best_attrs = s, e, tag, attrs
      end
    end
    if not best_s then
      break
    end
    -- track the last ===Sub heading=== before this block
    local before = "\n" .. wikitext:sub(pos, best_s - 1)
    for line in before:gmatch("\n([^\n]*)") do
      local h = line:match("^=+%s*(.-)%s*=+%s*$")
      if h and not h:find("{{header", 1, true) then
        current_sub = M.strip_markup(h)
      end
    end
    local close_s, close_e = wikitext:find("</" .. best_tag .. "%s*>", best_e + 1)
    if not close_s then
      break
    end
    local code = wikitext:sub(best_e + 1, close_s - 1):gsub("^\r?\n", ""):gsub("%s+$", "")
    local lang = best_attrs:match('lang%s*=%s*"?([%w%+#%-_]+)') or (best_tag == "lang" and best_attrs:match("^%s*([%w%+#%-_]+)"))
    if code ~= "" then
      blocks[#blocks + 1] = { title = current_sub, lang = lang, code = code }
    end
    pos = close_e + 1
  end
  return blocks
end

--- One display name per code block, in block order: the subheading, numbered when
--- several blocks share it ("Recursive (2)"), or "#3" for blocks without one.
--- Second result: each block's occurrence number among blocks with the same subheading.
function M.variant_names(blocks)
  local count, seen, names, nth = {}, {}, {}, {}
  for _, b in ipairs(blocks) do
    if b.title then
      count[b.title] = (count[b.title] or 0) + 1
    end
  end
  for i, b in ipairs(blocks) do
    if b.title then
      seen[b.title] = (seen[b.title] or 0) + 1
      nth[i] = seen[b.title]
    end
    -- decoded again: entries cached before entity decoding covered "&Ouml;" kept it raw
    local shown = b.title and M.strip_markup(b.title)
    if not b.title then
      names[i] = "#" .. i
    elseif count[b.title] > 1 then
      names[i] = ("%s (%d)"):format(shown, nth[i])
    else
      names[i] = shown
    end
  end
  return names, nth
end

--- The block a completion item refers to. `index`/`sub` were recorded when the menu was
--- built; if the page has changed since, find the `nth` block under that subheading
--- again, else fall back.
function M.pick_block(blocks, index, sub, nth)
  if not index then
    return blocks[1]
  end
  if sub then
    local seen, first = 0, nil
    for _, b in ipairs(blocks) do
      if b.title == sub then
        seen = seen + 1
        first = first or b
        if seen == (nth or 1) then
          return b
        end
      end
    end
    if first then
      return first
    end
  end
  return blocks[index] or blocks[1]
end

--- Strip wiki markup down to readable prose (for the docs popup).
function M.strip_markup(s)
  s = s:gsub("<[^>]->", "")
  s = s:gsub("%[%[[^%]|]-|([^%]]-)%]%]", "%1")
  s = s:gsub("%[%[([^%]]-)%]%]", "%1")
  s = s:gsub("'''?", "")
  s = s:gsub("{{[^}]-}}", "")
  return decode_entities(s)
end

return M
