-- 空闲修剪实测：热身后读 RSS → 空闲 TIGER_MODEL_TRIM_SEC → 再解码触发修剪 → 读 RSS。
-- 用法: lua probe_trim.lua <root> <lexicon> <corpus> <句数>
local root, lexicon, corpus, n = arg[1], arg[2], arg[3], tonumber(arg[4])
package.path = root .. "/tiger_sentence_native/?.lua;" .. root .. "/lua/?.lua;" .. package.path
local mod = require("mohu_sentence")
local values = {
  ["tiger/engine_lib"] = root .. "/tiger_sentence_native/libtigerengine.dylib",
  ["tiger/model"] = root .. "/tiger_sentence_native/mohu-sentence-ngram-v5.bin",
  ["tiger/lexicon"] = lexicon,
  ["tiger/scheme"] = "tiger", ["tiger/all_ranks"] = "false",
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
assert(mod.native_ready(), "engine unavailable")

local sents = {}
for line in io.lines(corpus) do
  sents[#sents + 1] = line:match("^[^\t]+\t([^\t]+)")
  if #sents >= n then break end
end
local pid = io.popen("echo $PPID"):read()
local function rss_mb()
  local s = io.popen("ps -o rss= -p " .. pid):read()
  return math.floor(tonumber(s) / 1024)
end
local function burst(k)
  for i = 1, k do
    local raw = sents[((i - 1) % #sents) + 1]
    mod.decode_with_early(raw)
  end
end
local function sleep(t) io.popen("sleep " .. t):read() end

burst(#sents)
print(string.format("热身后(%d 句): %d MB", #sents, rss_mb()))
sleep(5)
burst(1)  -- 空闲超阈值 → 入口触发 madvise 修剪
sleep(0.2)
print(string.format("空闲修剪后:    %d MB", rss_mb()))
burst(30)
print(string.format("再打 30 句后:  %d MB", rss_mb()))
