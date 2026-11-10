-- 用户虎单码表三臂离线配对基准（本仓原生引擎，无学习回调/用户快照）。
-- 用法: lua driver.lua <arm> <root> <corpus.tsv> <start> <count> <out.tsv> <lexicon> <all_ranks>
local arm, root, corpus = arg[1], arg[2], arg[3]
local start, count, output = tonumber(arg[4]), tonumber(arg[5]), arg[6]
local lexicon, all_ranks = arg[7], arg[8]
assert(arm and root and corpus and start and count and output and lexicon and all_ranks,
  "usage: driver.lua <arm> <root> <corpus> <start> <count> <out> <lexicon> <all_ranks>")
local file = assert(io.open(output, "w"))
local utf8_len = function(s) return assert(utf8.len(s)) end

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
print(arm, "status", mod.engine_status and mod.engine_status() or "n/a")
local proc = dofile(root .. "/lua/tiger_mode_proc.lua")
local test = proc._test
test.set_engine_module(mod)

local hist, latencies = {}, {}
local total, total_keys, total_ms = 0, 0, 0
local function run(id, word, raw, bounds_s)
  local bounds = {}
  for n in bounds_s:gmatch("%d+") do bounds[#bounds + 1] = tonumber(n) end
  assert(#bounds == #raw and bounds[#bounds] == utf8_len(word), "invalid character boundaries")
  local props, committed, wrong = {}, "", false
  local ncommits, sum_pk, sum_pc, sum_ms, max_ms = 0, 0, 0, 0, 0
  local typed, final_pk, final_pc = 0, 0, 0
  local ctx = { input = "" }
  function ctx:push_input(s) self.input = self.input .. s end
  function ctx:clear() self.input = "" end
  function ctx:is_composing() return self.input ~= "" end
  function ctx:get_property(k) return props[k] or "" end
  function ctx:set_property(k, v) props[k] = v end
  function ctx:get_option(k)
    return k == "sentence" or k == "early_commit" or k == "tiger_sentence_early_commit"
  end
  local env = { engine = { context = ctx, schema = { config = config } } }
  function env.engine:commit_text(text)
    ncommits = ncommits + 1
    committed = committed .. text
    if word:sub(1, #committed) ~= committed then
      wrong = true
      file:write(table.concat({"W", id, typed, text, committed}, "\t"), "\n")
    end
  end
  proc.processor.init(env)
  for i = 1, #raw do
    typed = i
    local key = {
      repr = function() return raw:sub(i, i) end,
      release = function() return false end,
      ctrl = function() return false end, alt = function() return false end,
      super = function() return false end, shift = function() return false end,
      keycode = 0,
    }
    local t0 = os.clock()
    proc.processor.func(key, env)
    local ms = (os.clock() - t0) * 1000
    sum_ms = sum_ms + ms
    max_ms = math.max(max_ms, ms)
    total_keys = total_keys + 1
    if total_keys % 4 == 1 then latencies[#latencies + 1] = ms end
    local pk = #ctx.input
    local pc = math.max(0, bounds[i] - utf8_len(committed))
    sum_pk, sum_pc = sum_pk + pk, sum_pc + pc
    hist[pk] = (hist[pk] or 0) + 1
    final_pk, final_pc = pk, pc
  end
  local final = committed
  if ctx.input ~= "" then
    local prefix, cr = test.state.committed_text or "", test.state.committed_raw or ""
    local decoded = mod.decode_with_early(cr .. ctx.input)
    for _, item in ipairs(decoded and decoded.items or {}) do
      if prefix == "" then final = final .. item.text; break end
      if #item.text > #prefix and item.text:sub(1, #prefix) == prefix
          and item.raw_lengths and tonumber(item.raw_lengths[#prefix]) == #cr then
        final = final .. item.text:sub(#prefix + 1)
        break
      end
    end
  end
  file:write(table.concat({"R", id, word, raw, committed, final, wrong and 1 or 0,
    ncommits, sum_pk, sum_pc, final_pk, final_pc, sum_ms, max_ms,
    utf8_len(word), utf8_len(committed)}, "\t"), "\n")
  total, total_ms = total + 1, total_ms + sum_ms
  if total % 1000 == 0 then
    file:flush()
    print(arm, start, total, string.format("%.1fs CPU", total_ms / 1000))
    io.stdout:flush()
  end
end
for id, line in (function()
  local lines, id = io.lines(corpus), 0
  return function() local line = lines(); if line then id = id + 1; return id, line end end
end)() do
  if id >= start + count then break end
  if id >= start then
    local word, raw, bounds = line:match("^([^\t]+)\t([a-z]+)\t([0-9,]+)$")
    assert(word and raw and bounds, "invalid corpus line " .. id)
    run(id, word, raw, bounds)
  end
end
assert(total == count, "incomplete corpus shard")
for k, n in pairs(hist) do file:write("H\t", k, "\t", n, "\n") end
for _, ms in ipairs(latencies) do file:write(string.format("L\t%.6f\n", ms)) end
file:write("DONE\t", total, "\t", total_keys, "\n")
file:close()
print(arm, "DONE", start, total)
