if vim.g.loaded_rosettascraper then
  return
end
vim.g.loaded_rosettascraper = true

vim.api.nvim_create_user_command("Rosetta", function(args)
  require("rosettascraper").pick(args.args)
end, { nargs = "?", desc = "Insert a Rosetta Code implementation for the current filetype" })

vim.api.nvim_create_user_command("RosettaClearCache", function()
  require("rosettascraper.api").clear_cache()
end, { desc = "Forget cached Rosetta Code lookups" })
