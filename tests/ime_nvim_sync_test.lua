local ON_KEYS = { "<F19>", "<S-F7>" }
local OFF_KEYS = { "<F24>", "<S-F12>" }
local ALL_KEYS = { "<F19>", "<S-F7>", "<F24>", "<S-F12>" }
local checks = 0

local function expect(actual, expected, context)
  assert(actual == expected, context .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  checks = checks + 1
end

local function new_runtime(is_mac)
  local runtime = {
    mode = "i",
    output = "1\n",
    executable = 1,
    queries = 0,
    commands = {},
    timers = {},
    mappings = {},
  }
  local stub = {
    api = { nvim_get_mode = function() return { mode = runtime.mode } end },
    cmd = function(command) table.insert(runtime.commands, command) end,
    v = { shell_error = 0 },
    trim = function(value) return value:match("^%s*(.-)%s*$") end,
    keymap = {
      set = function(modes, key, callback, opts)
        expect(opts.silent, true, "通知を無音で処理する")
        expect(opts.noremap, true, "通知を再マップしない")
        for _, mode in ipairs(modes) do
          runtime.mappings[mode] = runtime.mappings[mode] or {}
          runtime.mappings[mode][key] = callback
        end
      end,
    },
    fn = {
      has = function(feature)
        expect(feature, "mac", "OS判定")
        return is_mac and 1 or 0
      end,
      executable = function(command)
        expect(command, "fcitx5-remote", "IME照会コマンド")
        return runtime.executable
      end,
      system = function(args)
        expect(#args, 1, "IME状態を変更する引数を渡さない")
        expect(args[1], "fcitx5-remote", "実IME状態を照会する")
        runtime.queries = runtime.queries + 1
        return runtime.output
      end,
    },
    defer_fn = function(callback, delay)
      expect(delay, 50, "既存のデバウンス時間を維持する")
      table.insert(runtime.timers, callback)
    end,
  }

  local chunk = assert(loadfile("nvim/lua/ime_nvim_sync.lua"))
  setfenv(chunk, setmetatable({ vim = stub }, { __index = _G }))
  runtime.module = chunk()
  runtime.v = stub.v

  function runtime.flush()
    local timers = runtime.timers
    runtime.timers = {}
    for _, callback in ipairs(timers) do
      callback()
    end
  end

  function runtime.notify(key)
    local mapping_mode = runtime.mode:sub(1, 1) == "i" and "i" or "n"
    runtime.mappings[mapping_mode][key]()
    runtime.flush()
  end

  return runtime
end

-- intent: 両OSで既定動作を維持し、falseではIME OFF時の現在モードを保持する。
for _, is_mac in ipairs({ false, true }) do
  for _, setting in ipairs({ "default", true, false }) do
    for _, mode in ipairs({ "i", "n" }) do
      for _, key in ipairs(is_mac and OFF_KEYS or ALL_KEYS) do
        local runtime = new_runtime(is_mac)
        runtime.mode = mode
        if setting ~= "default" then
          runtime.module.setup({ normal_on_ime_off = setting })
        end
        runtime.notify(key)
        local should_stop = setting ~= false and mode == "i"
        expect(#runtime.commands, should_stop and 1 or 0, "IME OFFのモード変更回数")
        if should_stop then
          expect(runtime.commands[1], "stopinsert", "IME OFFでノーマルモードへ移行する")
        end
      end
    end

    -- intent: OFF時の設定によらずIME ONで挿入モードへ入り、挿入中は重複変更しない。
    for _, mode in ipairs({ "n", "i" }) do
      for _, key in ipairs(is_mac and ON_KEYS or ALL_KEYS) do
        local runtime = new_runtime(is_mac)
        runtime.mode = mode
        runtime.output = "2\n"
        if setting ~= "default" then
          runtime.module.setup({ normal_on_ime_off = setting })
        end
        runtime.notify(key)
        expect(#runtime.commands, mode == "n" and 1 or 0, "IME ONのモード変更回数")
        if mode == "n" then
          expect(runtime.commands[1], "startinsert", "IME ONで挿入モードへ移行する")
        end
      end
    end
  end

  -- intent: 設定無効時も編集対象外の各モードで通知キーを入力として消費する。
  local runtime = new_runtime(is_mac)
  runtime.module.setup({ normal_on_ime_off = false })
  for _, mode in ipairs({ "x", "s", "o", "c", "t" }) do
    for _, key in ipairs(ALL_KEYS) do
      expect(runtime.mappings[mode][key], "<Nop>", "編集対象外の通知抑止")
    end
  end

  -- intent: setupの省略値で既定動作を復元し、登録済みコールバックにも反映する。
  for _, reset in ipairs({ function() runtime.module.setup() end, function() runtime.module.setup({}) end }) do
    runtime.module.setup({ normal_on_ime_off = false })
    reset()
    runtime.commands = {}
    runtime.notify("<F24>")
    expect(runtime.commands[1], "stopinsert", "設定を既定値へ戻す")
  end

  -- intent: 不正な設定はエラーとなり、直前の有効なfalse設定を破壊しない。
  for _, invalid in ipairs({ false, 1, "false", { normal_on_ime_off = 0 }, { normal_on_ime_off = "false" } }) do
    runtime.module.setup({ normal_on_ime_off = false })
    expect(pcall(runtime.module.setup, invalid), false, "不正型の拒否")
    runtime.commands = {}
    runtime.notify("<F24>")
    expect(#runtime.commands, 0, "不正設定後も以前の設定を維持する")
  end
end

-- intent: Linuxの前後通知を一回にまとめ、最後の実IME状態を使う。
for _, setting in ipairs({ true, false }) do
  local runtime = new_runtime(false)
  runtime.module.setup({ normal_on_ime_off = setting })
  runtime.mappings.i["<F19>"]()
  runtime.mappings.i["<F24>"]()
  runtime.flush()
  expect(runtime.queries, 1, "前後通知をデバウンスする")
  expect(#runtime.commands, setting and 1 or 0, "デバウンス後も設定を適用する")
end

-- intent: Linuxでコマンド不在・失敗・未知状態の場合は設定によらずモードを変更しない。
for _, setting in ipairs({ true, false }) do
  for _, failure in ipairs({ "missing", "failed", "0", "3", "invalid", "" }) do
    local runtime = new_runtime(false)
    runtime.module.setup({ normal_on_ime_off = setting })
    if failure == "missing" then
      runtime.executable = 0
    elseif failure == "failed" then
      runtime.v.shell_error = 1
    else
      runtime.output = failure
    end
    runtime.notify("<F24>")
    expect(#runtime.commands, 0, "IME照会失敗または未知状態で無操作")
    expect(runtime.queries, failure == "missing" and 0 or 1, "コマンド不在なら実行しない")
  end
end

print("ime_nvim_sync: " .. checks .. " checks passed")
