# wayback.nvim

Diff any file — or a whole directory — against a point in its Neovim undo
history. No git required: it reconstructs past content purely from
Neovim's persistent undofiles.

## Requirements

- Neovim with `vim.opt.undofile = true` set (files must have been edited in
  Neovim before, so an undofile actually exists).
- [telescope.nvim](https://github.com/nvim-telescope/telescope.nvim) (for the picker UI).
- [git-delta](https://github.com/dandavison/delta) on your `$PATH` (for the diff view).

## Install (lazy.nvim)

```lua
{
  "yourname/wayback.nvim",
  dependencies = { "nvim-telescope/telescope.nvim" },
  opts = {
    scan_window_secs = 24 * 3600, -- default scan window
    extensions = nil,             -- e.g. { "lua", "py" } to restrict by filetype
  },
  cmd = { "WaybackDiff", "WaybackDirDiff" },
  keys = {
    { "<leader>uw", "<cmd>WaybackDiff<cr>", desc = "Wayback: diff current buffer" },
    { "<leader>uW", "<cmd>WaybackDirDiff<cr>", desc = "Wayback: diff directory" },
  },
}
```

(`opts = {...}` with lazy.nvim automatically calls `require("wayback").setup(opts)`.)

## Usage

```vim
:WaybackDiff              " current buffer, opens a time picker (last 24h)
:WaybackDiff 1h           " current buffer, diff directly against 1 hour ago
:WaybackDiff 1d
:WaybackDiff 2026-08-15T10:00

:WaybackDirDiff           " whole cwd, opens a time picker (last 24h)
:WaybackDirDiff src/      " scoped to src/, opens a time picker
```

### Picker

Each row is one `(file, timestamp)` pair, sorted newest first, showing how
long ago it changed, the absolute timestamp, the filename, and
`+added -removed ~changed` line counts. Entries older than 1h are dimmed;
older than 1d are further dimmed.

- `<CR>` — open a delta-rendered diff of that file at that point in time.
- `R` — explicitly rescan further back than the default window (prompts for
  a duration like `3d` or `7d`). This is opt-in so the default stays fast.

### Diff view

- `t` — jump back to the picker to pick a different point in time, without
  rescanning.
- `q` — close the diff view.

## Config

```lua
require("wayback").setup({
  scan_window_secs = 24 * 3600, -- how far back to scan by default
  extensions = { "lua", "py" }, -- restrict scanning to these file extensions; nil = all files
  delta_cmd = "delta --paging=always ...", -- override the delta invocation used for the diff view
})
```
