# IME / Neovim mode synchronization

Target setup:

- Linux: GNOME + xremap + fcitx5-mozc + kitty + Neovim
- macOS: Karabiner-Elements + Google Japanese Input + kitty + Neovim
- Shells: bash and zsh
- IME toggle key: `Shift+Space`
- Transport keys: `Shift+F7` and `Shift+F12`

The intended behavior is:

- turning Japanese input **ON** makes Neovim enter **Insert mode**;
- turning Japanese input **OFF** makes Neovim enter **Normal mode** by default; this can be disabled to keep the current mode;
- pressing plain `i` in Normal mode still enters Insert mode **without changing the IME**;
- at ordinary bash/zsh prompts, `Shift+Space` toggles the IME without leaving escape-sequence junk on the command line.

## Why Shift+F7 / Shift+F12?

Direct F19/F24 injection was tested on Linux. xremap correctly emitted `KEY_F19` and `KEY_F24` at the evdev layer, but the GNOME/Wayland/fcitx5 path did not deliver them to kitty as usable function keys. fcitx5's key trace showed unresolved keysyms for their XKB keycodes.

`Shift+F7` and `Shift+F12` pass through the same stack reliably, so they are used as the physical transport keys instead.

In kitty/terminal function-key compatibility, shifted F-keys can be represented as higher-numbered function keys. In the tested Neovim setup:

```text
Shift+F7  -> <F19>
Shift+F12 -> <F24>
```

The supplied Neovim module accepts **both** spellings (`<S-F7>`/`<F19>` and `<S-F12>`/`<F24>`) so it remains robust if terminal behavior differs.

## Design

Transport keys are injected only while kitty is the target/frontmost application. Other GUI applications only get the IME toggle behavior.

### Linux

xremap cannot directly make the remap depend on fcitx5's current active/inactive state, so it sends a transport key on **both sides** of the existing `Shift+Space` toggle:

```text
Shift+F7 -> Shift+Space -> Shift+F12
```

Neovim treats either transport key as "re-read the real fcitx5 state" and, after a short debounce, calls `fcitx5-remote`:

- state `2` -> Insert mode
- state `1` -> Normal mode, unless `normal_on_ime_off = false`

### macOS

Karabiner can inspect the current Google Japanese Input source before transforming the key, so it sends an unambiguous notification:

```text
Google Japanese Input: Direct   -> Shift+Space -> Shift+F7 -> Kana
Google Japanese Input: Japanese -> Shift+Space -> Eisu -> Shift+F12
```

In Neovim:

- Shift+F7 (often seen as F19) -> Insert mode
- Shift+F12 (often seen as F24) -> Normal mode, unless `normal_on_ime_off = false`

Outside kitty, the Karabiner rule performs only the Google Japanese Input switch and does not emit the transport keys.

## 1. Linux: xremap

Use `linux/xremap.yml`, or merge its `keymap` entry into your existing xremap configuration.

The file assumes xremap sees kitty's application name as `kitty`. If it does not match on your GNOME setup, inspect the application name reported by xremap and change:

```yaml
application:
  only: kitty
```

The config uses xremap's `sleep` action. Your existing fcitx5 `Shift+Space` toggle remains the real IME switch.

## 2. macOS: Karabiner-Elements

Copy:

```text
macos/karabiner-ime-nvim.json
```

to:

```text
~/.config/karabiner/assets/complex_modifications/karabiner-ime-nvim.json
```

Then open Karabiner-Elements:

1. **Complex Modifications**
2. **Add predefined rule**
3. enable **Google Japanese Input + Neovim mode sync**

The supplied file expects:

```text
kitty bundle id:
  net.kovidgoyal.kitty

Google Japanese Input direct mode:
  com.google.inputmethod.Japanese.Roman

Google Japanese Input Japanese modes:
  com.google.inputmethod.Japanese.base
  com.google.inputmethod.Japanese.Katakana
  com.google.inputmethod.Japanese.HalfWidthKana
  com.google.inputmethod.Japanese.FullWidthRoman
```

Verify your installation in **Karabiner-EventViewer**:

- **Variables** tab: `input_source_id`
- **Frontmost Application** tab: kitty bundle identifier

If your Google Japanese Input build reports different IDs, update the regexes in the JSON.

Karabiner evaluates manipulators from top to bottom and only applies the first matching one. The kitty-specific entries therefore deliberately appear before the general fallback entries.

## 3. Neovim

Copy:

```text
nvim/lua/ime_nvim_sync.lua
```

to:

```text
~/.config/nvim/lua/ime_nvim_sync.lua
```

and add this to `init.lua`:

```lua
require("ime_nvim_sync")
```

To keep the current Neovim mode when Japanese input is turned **OFF**, replace that line with:

```lua
require("ime_nvim_sync").setup({
  normal_on_ime_off = false,
})
```

`normal_on_ime_off` defaults to `true`. With `false`, turning the IME off in Insert mode keeps Insert mode; turning it off in Normal mode keeps Normal mode. Turning the IME **ON** still enters Insert mode on both Linux and macOS.

`setup()` accepts an optional table and requires `normal_on_ime_off` to be a boolean when supplied. Each call applies the defaults again, so `setup()` or `setup({})` restores `normal_on_ime_off = true`. Invalid values raise an error without changing the current setting.

The module accepts both terminal representations:

```text
<S-F7>  or <F19>
<S-F12> or <F24>
```

Linux and macOS are detected automatically with `vim.fn.has("mac")`.

On Linux, the 50 ms delay is intentional: it lets the fcitx5 toggle settle before `fcitx5-remote` is queried, and it debounces the two transport events. If your environment is consistently slower, increase `50` slightly.

The transport keys are swallowed in command-line, terminal-buffer, Visual/Select, and operator-pending modes so they do not accidentally become editor input there.

## 4. bash

Append `shell/bashrc.snippet` to `~/.bashrc`.

Reload:

```bash
source ~/.bashrc
```

At a normal shell prompt kitty's legacy encodings for these modified function keys are expected to be:

```text
Shift+F7  -> ESC [ 18 ; 2 ~
Shift+F12 -> ESC [ 24 ; 2 ~
```

The snippet swallows those, plus F19/F24 CSI-u forms as harmless fallbacks.

## 5. zsh

Append `shell/zshrc.snippet` to `~/.zshrc`.

Reload:

```zsh
source ~/.zshrc
```

## 6. Verification

### Linux: evdev/xremap

If needed, run:

```bash
sudo evtest
```

Select the `xremap` virtual device and confirm the sequence contains `KEY_F7` with Shift, `KEY_SPACE` with Shift, then `KEY_F12` with Shift.

### kitty key transport

Run:

```bash
kitten show-key -m kitty
```

Press the physical `Shift+Space` and confirm the transport key events appear around the IME toggle as expected. The actual `Shift+Space` itself may be consumed by fcitx5, which is normal.

### Shell

At a plain bash or zsh prompt:

1. press `Shift+Space` repeatedly;
2. confirm Japanese input toggles;
3. confirm no escape-sequence debris appears on the command line.

### Linux / fcitx5 / Neovim

Run:

```bash
fcitx5-remote
```

and confirm it changes between inactive (`1`) and active (`2`) as you toggle the IME.

Then in Neovim:

1. start in Normal mode with IME off;
2. `Shift+Space` -> expect IME on + Insert mode;
3. `Shift+Space` -> expect IME off + Normal mode by default, or Insert mode with `normal_on_ime_off = false`;
4. press `i` from Normal mode -> expect Insert mode while IME remains unchanged.

If you want to see what Neovim calls the transport keys, temporarily map/inspect `<S-F7>`, `<F19>`, `<S-F12>`, and `<F24>`. On the tested Linux setup the shifted keys are observed as `<F19>` and `<F24>`.

### macOS / Google Japanese Input

Use Karabiner-EventViewer first to verify the input source IDs. Then repeat the same Neovim behavior test above.

### Local regression tests

Run from the repository root:

```bash
NVIM_LOG_FILE=/tmp/ime-nvim-sync-tests.log nvim --headless -u NONE -i NONE -n \
  -c 'lua local ok, err = pcall(dofile, "tests/ime_nvim_sync_test.lua"); if not ok then print(err); vim.cmd("cquit 1") end' \
  -c 'qa!'
```

The tests stub the OS and IME APIs to check both platform paths, configuration, and Linux debounce/error handling without switching the real IME. They do not verify the physical key transport or real IME timing.

## References

- xremap configuration and key sequences: https://github.com/xremap/xremap
- xremap actions (`sleep`): https://github.com/xremap/xremap/blob/master/doc/reference_actions.md
- Karabiner input source conditions: https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/input-source/
- Karabiner `to.modifiers`: https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/to/modifiers/
- Karabiner frontmost application condition: https://karabiner-elements.pqrs.org/docs/json/complex-modifications-manipulator-definition/conditions/frontmost-application/
- Karabiner file locations: https://karabiner-elements.pqrs.org/docs/json/location/
- kitty keyboard protocol: https://sw.kovidgoyal.net/kitty/keyboard-protocol/
- Neovim TUI / CSI-u support: https://neovim.io/doc/user/tui/
