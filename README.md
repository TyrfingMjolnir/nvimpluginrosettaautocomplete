# nvim-rosettascraper

Completion source that queries [Rosetta Code](https://rosettacode.org) live while you type.
Start typing an identifier like `binary_search`, `quickSort` or `fibonacci`. Matching Rosetta Code
tasks appear in your completion menu, the docs popup shows the implementation in your buffer's
language, and accepting an item replaces the word with that code.

Works with **blink.cmp** and **nvim-cmp**. Requires Neovim ≥ 0.10 and `curl`.

## The core purpose of this plugin is to have conceptual snippets available to learn how to code
using this snippets, rosetta code is the source for now.

## How it works

1. The word before the cursor (`binarySearch` / `binary_search` / `binary-search`) becomes the
   query `binary search`, which is sent to the MediaWiki `prefixsearch` API (debounced, cached).
2. When an item is selected, the page's sections are fetched, and only the section for your
   filetype's language (`lua` → `Lua`, `cpp` → `C++`, …) is downloaded and parsed for
   `<syntaxhighlight>` / `<lang>` blocks.
3. Tasks whose implementation has several variants are listed once per variant, labelled with the
   page's subheading: `Fibonacci sequence › Recursive`, `› Tail Recursive`, `› Iterative`, …
   So `fibonacci_tail` narrows the menu to the tail-recursive version. To know the variants the
   code has to be downloaded, so the top `variant_prefetch` hits are fetched while the menu is built
   (waiting at most `variant_wait_ms`). A page that hasn't arrived by then is shown as one task
   item and splits into variants on your next keystroke; after that it comes from the cache.
   Tasks found to have no implementation in your language are left out of the menu
   (with `insert = "name"` they stay, since the task name is what gets inserted).
4. If the identifier matches no task title (`fibonacci_tail`), trailing words are dropped until one
   does (`fibonacci`), and the completion engine's fuzzy matcher narrows the results.
5. When you accept an item, the inserted identifier is replaced by that variant's code (the first
   block for a plain task item), re-indented to the current line. If there's no implementation in
   your language, the identifier stays.

## Offline use

Every lookup is saved to `stdpath("data")/rosettascraper/cache.json` (about 40 KB per implementation).
Anything you have already seen is available offline, after restarts too:

- Implementations you've looked at in the docs popup, accepted, or inserted with `:Rosetta` are
  served from the cache.
- Offline, the completion menu searches the cache, so `bin` still offers `Binary search` if you
  fetched its implementation before.
- After a network error the plugin uses only the cache for 30 s, then tries the network again.
  Lookups that were never cached show "offline, and not cached yet".
- When you're online, entries older than `cache_ttl_days` are refreshed. If the refresh fails, the
  old copy is used.

## Install (lazy.nvim)

```lua
{ "you/nvim-rosettascraper", opts = {} }
```

### blink.cmp

```lua
sources = {
  default = { "lsp", "path", "snippets", "buffer", "rosetta" },
  providers = {
    rosetta = { name = "Rosetta", module = "rosettascraper.blink", async = true, score_offset = -5 },
  },
},
```

### nvim-cmp

`setup()` registers the source as `rosetta` when cmp is installed:

```lua
cmp.setup({ sources = { { name = "nvim_lsp" }, { name = "rosetta" } } })
```

## Commands

- `:Rosetta [query]`: pick a task (defaults to the word under the cursor), then a variant, and insert it below the cursor.
- `:RosettaClearCache`: clear the cached lookups, in memory and on disk.

## Options

```lua
require("rosettascraper").setup({
  min_chars = 4,          -- don't query for shorter words
  max_results = 20,
  debounce_ms = 250,
  timeout = 10,           -- curl --max-time
  insert = "code",        -- or "name" to insert only the identifier
  languages = { mylang = "Some Rosetta Language" }, -- extra filetype mappings
  filetypes = nil,        -- restrict to a list of filetypes
  doc_max_blocks = 3,
  variants = true,        -- one item per implementation variant; false = one per task
  variant_prefetch = 8,   -- search hits whose code is fetched to list their variants
  variant_wait_ms = 800,  -- max wait for that fetch before the menu is shown
  cache_path = vim.fn.stdpath("data") .. "/rosettascraper/cache.json", -- false = memory only
  cache_ttl_days = 30,    -- refresh older entries when online
})
```

## Tests

```sh
lua tests/parse_spec.lua            # pure-Lua parser tests
lua tests/parse_spec.lua dump.txt   # also parse a wikitext section saved from the API
```
