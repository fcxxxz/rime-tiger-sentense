-- Sync common Rime options across engine contexts.
-- 2026-11-16 并集版：lua/ 目录为全方案共享，本文件需同时服务整句仓
-- （tiger_sentence）与用户同装的 rime-tiger 单字全家桶（tiger/tigress/PY_c）。
-- COMMON 取两生态开关名并集；SCHEMA_OPTIONS 各方案专属名单，未命中落 COMMON。
-- 未安装的方案条目只是死数据（查表不命中），不产生任何副作用。

local option_state = require("option_state")

local M = {}
local kNoop = 2
local syncing = false
local SYNC_INTERVAL_MS = 250

local function now_ms()
  if rime_api and rime_api.get_time_ms then
    return rime_api.get_time_ms()
  end
  return math.floor(os.clock() * 1000)
end

-- 开关持久化与跨应用同步的唯一来源（default.yaml 不再配置 save_options，
-- user.yaml 不参与；此列表即需要持久化/同步的开关全集）。
local COMMON_OPTIONS = {
  "ascii_punct",
  "full_shape",
  -- rime-tiger 单字生态（tiger/tigress 及其未列条目的方案）
  "extended_char",
  "simplification",
  "pinyin",
  "emoji_cn",
  "input_speed_stat",
  "chaifen",
  "mars",
  "charset_comment_filter",
  "udpf_switch",
  -- 魔虎生态（整句仓开发用 mohu_zrm/mohu_flypy 落 COMMON）
  "extended_charset",
  "emoji",
  "inflexible",
  "unicode_comment",
  "contextual_order",
  "quick_code_hint",
  "aux_hint",
}

local SCHEMA_OPTIONS = {
  mohu_zrm = {
    "ascii_punct",
    "full_shape",
    "extended_charset",
    "emoji",
    "inflexible",
    "unicode_comment",
    "contextual_order",
    "quick_code_hint",
    "aux_hint",
  },
  mohu_flypy = {
    "ascii_punct",
    "full_shape",
    "extended_charset",
    "emoji",
    "inflexible",
    "unicode_comment",
    "contextual_order",
    "quick_code_hint",
    "aux_hint",
  },
  -- 虎码整句方案（id=tiger_sentence）：整句/提前上屏开关与反查码式（rev_flypy/rev_full）持久化。
  tiger_sentence = {
    "ascii_punct",
    "full_shape",
    "extended_charset",
    "emoji",
    "sentence",
    "early_commit",
    "rev_flypy",
    "rev_full",
  },
  -- 拼音反查方案（源自 rime-tiger 用户配置；未安装 PY_c 的机器上是死条目）。
  PY_c = {
    "ascii_punct",
    "full_shape",
    "simplification",
    "pinyin",
    "emoji_cn",
    "mars",
    "charset_comment_filter",
    "udpf_switch",
  },
}

-- 状态文件里还没有记录时使用的默认值。
local OPTION_DEFAULTS = {
  contextual_order = true,
  sentence = true,
  early_commit = true,
}

local function get_context(env)
  return env and env.engine and env.engine.context or nil
end

local function option_names(env)
  local schema = env and env.engine and env.engine.schema
  local schema_id = schema and schema.schema_id
  return SCHEMA_OPTIONS[schema_id] or COMMON_OPTIONS
end

local function save_options(env)
  local ctx = get_context(env)
  if ctx and ctx.get_option then
    local values = {}
    for _, name in ipairs(option_names(env)) do
      values[name] = ctx:get_option(name) and true or false
    end
    option_state.set_many(values)
  end
end

local function sync_options(env, force)
  if syncing then
    return
  end
  syncing = true
  option_state.sync_many(env, option_names(env), force, OPTION_DEFAULTS)
  syncing = false
end

function M.init(env)
  local ctx = get_context(env)
  if ctx and ctx.option_update_notifier and ctx.option_update_notifier.connect then
    env.option_sync_notifier = ctx.option_update_notifier:connect(function()
      if not syncing then
        save_options(env)
      end
    end)
  end
  env.option_sync_last_ms = now_ms()
  sync_options(env, true)
end

function M.fini(env)
  if env and env.option_sync_notifier and env.option_sync_notifier.disconnect then
    env.option_sync_notifier:disconnect()
  end
end

function M.func(key_event, env)
  if key_event and key_event.release and key_event:release() then
    return kNoop
  end
  local current_ms = now_ms()
  local last_ms = env and env.option_sync_last_ms
  if not last_ms or current_ms < last_ms or current_ms - last_ms >= SYNC_INTERVAL_MS then
    sync_options(env, false)
    if env then
      env.option_sync_last_ms = current_ms
    end
  end
  return kNoop
end

function M._test_options()
  return COMMON_OPTIONS
end

function M._test_option_names(schema_id)
  return SCHEMA_OPTIONS[schema_id] or COMMON_OPTIONS
end

return M
