-- 机制探针：验证「一简字 2 码次选」在 all_ranks=false（定顶）下不参与组句，
-- 在 all_ranks=true（竞争）下才参与；并打印 un/tu 等碰撞码位的实际首选。
-- 用法: lua probe_pin.lua <root> <lexicon> <all_ranks> [raw...]
local root, lexicon, all_ranks = arg[1], arg[2], arg[3]
package.path = root .. "/tiger_sentence_native/?.lua;" .. root .. "/lua/?.lua;" .. package.path
local mod = require("mohu_sentence")
local values = {
  ["tiger/engine_lib"] = root .. "/tiger_sentence_native/libtigerengine.dylib",
  ["tiger/model"] = root .. "/tiger_sentence_native/mohu-sentence-ngram-v5.bin",
  ["tiger/lexicon"] = root .. "/" .. lexicon,
  ["tiger/scheme"] = "tiger", ["tiger/all_ranks"] = all_ranks,
  ["tiger/user_model"] = "false", ["tiger/two_char_word_gate"] = "false",
  ["tiger/native_short_codes"] = "true",
}
local config = {
  get_string = function(_, key) return values[key] end,
  get_int = function() return nil end,
  get_bool = function(_, key)
    if values[key] == "true" then return true end
    if values[key] == "false" then return false end
    return nil
  end,
}
mod.translator.init({ engine = { schema = { config = config }, context = {} } })
assert(mod.native_ready(), "native engine unavailable")

local cases = {}
for i = 4, #arg do cases[#cases + 1] = arg[i] end
if #cases == 0 then
  -- 默认用例：含 的(un)/我(tu)/在(ng)/是(ot) 的真实串，以及皇/近 的上下文
  cases = { "unph", "tutnj", "ngtnj", "unwmgy", "tucjo", "ngheq" }
end
print(string.format("lexicon=%s all_ranks=%s", lexicon, all_ranks))
for _, raw in ipairs(cases) do
  local d = mod.decode_with_early(raw)
  local out = {}
  for i, item in ipairs((d and d.items) or {}) do
    if i > 5 then break end
    out[#out + 1] = item.text
  end
  print(string.format("  %-12s -> %s", raw, table.concat(out, " | ")))
end
