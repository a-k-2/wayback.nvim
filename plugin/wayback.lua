if vim.g.loaded_wayback then
  return
end
vim.g.loaded_wayback = true

-- Commands are created in require("wayback").setup(), not here, so the
-- plugin can be lazy-loaded on command/keymap without eagerly requiring
-- telescope or anything else until it's actually used.
