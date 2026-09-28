-- IME <-> Neovim mode synchronization for kitty.
--
-- Transport keys emitted by the OS remapper:
--   IME ON side  : Shift+F7
--   IME OFF side : Shift+F12
--
-- kitty/terminal compatibility may expose these to Neovim as <F19>/<F24>.
-- The mappings below therefore accept both representations.
--
-- macOS + Karabiner:
--   Shift+F7  (often seen as F19) = Google Japanese Input is being turned ON
--   Shift+F12 (often seen as F24) = Google Japanese Input is being turned OFF
--
-- Linux + xremap + fcitx5-mozc:
--   Both transport keys are synchronization notifications. After a short
--   delay, query fcitx5-remote and make Neovim match the actual IME state.

local M = {}

local ON_KEYS = { "<F19>", "<S-F7>" }
local OFF_KEYS = { "<F24>", "<S-F12>" }

local function mode_is_insert()
  return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
end

local function enter_insert()
  if not mode_is_insert() then
    vim.cmd("startinsert")
  end
end

local function enter_normal()
  if mode_is_insert() then
    vim.cmd("stopinsert")
  end
end

local function map_normal_and_insert(lhs, rhs)
  vim.keymap.set({ "n", "i" }, lhs, rhs, {
    silent = true,
    noremap = true,
  })
end

local function swallow_outside_normal_insert(lhs)
  vim.keymap.set({ "x", "s", "o", "c", "t" }, lhs, "<Nop>", {
    silent = true,
    noremap = true,
  })
end

local function map_each(keys, fn)
  for _, key in ipairs(keys) do
    map_normal_and_insert(key, fn)
  end
end

if vim.fn.has("mac") == 1 then
  -- Karabiner has already determined the direction of the IME change.
  map_each(ON_KEYS, enter_insert)
  map_each(OFF_KEYS, enter_normal)
else
  local generation = 0

  local function schedule_fcitx_sync()
    generation = generation + 1
    local mine = generation

    -- xremap emits one transport key on each side of Shift+Space. Debounce
    -- the pair and wait for fcitx5 to finish changing state before querying.
    vim.defer_fn(function()
      if mine ~= generation then
        return
      end

      if vim.fn.executable("fcitx5-remote") ~= 1 then
        return
      end

      local output = vim.fn.system({ "fcitx5-remote" })
      if vim.v.shell_error ~= 0 then
        return
      end

      local state = tonumber(vim.trim(output))

      -- fcitx5-remote:
      --   2 = active IME
      --   1 = inactive IME
      -- Other values are intentionally ignored.
      if state == 2 then
        enter_insert()
      elseif state == 1 then
        enter_normal()
      end
    end, 50)
  end

  map_each(ON_KEYS, schedule_fcitx_sync)
  map_each(OFF_KEYS, schedule_fcitx_sync)
end

for _, key in ipairs({ "<F19>", "<S-F7>", "<F24>", "<S-F12>" }) do
  swallow_outside_normal_insert(key)
end

return M
