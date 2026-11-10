-- Real native decode + processor + commit notifier + online-learning regression.
local root = arg[1] or "."
local mode = arg[2] or "whole"
package.path = root .. "/tiger_sentence_native/?.lua;" .. root .. "/lua/?.lua;" .. package.path
local native = require("mohu_sentence")
local values = {
  ["tiger/engine_lib"] = root .. "/tiger_sentence_native/libtigerengine.dylib",
  ["tiger/model"] = root .. "/tiger_sentence_native/mohu-sentence-ngram-v5.bin",
  ["tiger/lexicon"] = root .. "/tiger_sentence_native/data/tiger/tiger.lexicon.txt",
  ["tiger/scheme"] = "tiger",
  ["tiger/all_ranks"] = "false",
  ["tiger/two_char_word_gate"] = "false",
  ["tiger/native_short_codes"] = "true",
  ["tiger/user_model_snapshot"] = os.tmpname() .. ".snapshot",
}
local cfg = {
  get_string = function(_, key) return values[key] end,
  get_int = function() return nil end,
  get_bool = function() return nil end,
}
local connections = {}
local ctx = { input = "", properties = {}, committed = "" }
ctx.commit_notifier = {
  connect = function(_, callback)
    local connection = { callback = callback }
    function connection:disconnect() self.disconnected = true end
    connections[#connections + 1] = connection
    return connection
  end,
}
function ctx:get_option() return true end
function ctx:set_property(key, value) self.properties[key] = value end
function ctx:get_property(key) return self.properties[key] or "" end
function ctx:push_input(value) self.input = self.input .. value end
function ctx:clear() self.input = "" end
function ctx:get_commit_text() return self.last_commit or "" end
local commits, learning_updates = {}, 0
local engine = { schema = { config = cfg }, context = ctx }
function engine:commit_text(text)
  commits[#commits + 1] = text
  ctx.committed = ctx.committed .. text
  ctx.last_commit = text
  for _, connection in ipairs(connections) do
    if not connection.disconnected then connection.callback(ctx) end
  end
end
-- Wrap only the update call to prove the real notifier reached the native API.
local loadlib = package.loadlib
package.loadlib = function(...)
  local loader, err = loadlib(...)
  if not loader then return loader, err end
  return function(...)
    local api = loader(...)
    local update = assert(api.update_user_model)
    api.update_user_model = function(...)
      local rc = update(...)
      assert(rc == 1, "online learning must succeed")
      learning_updates = learning_updates + 1
      return rc
    end
    return api
  end
end
local translator_env = { engine = engine }
native.translator.init(translator_env)
package.loadlib = loadlib
assert(native.native_ready(), "native engine must be available; no fallback/skip")
local proc = dofile(root .. "/lua/tiger_mode_proc.lua")
local processor_env = { engine = engine }
proc.processor.init(processor_env)
proc._test.set_engine_module(native)
local suffix = "uehawdqupxnvabhueueuqrp"
local prefix = "dukgrkauxdgafmakmnfkke"
local raw = mode == "tail" and suffix or prefix .. suffix
local target = mode == "tail" and "的情况进行有效的控制"
    or "无法对那种病毒感染的情况进行有效的控制"
local started = os.clock()
for i = 1, #raw do
  local key = raw:sub(i, i)
  assert(proc.processor.func({ repr = function() return key end }, processor_env) == 1)
  local state = proc._test.state
  assert(state.committed_raw .. ctx.input == raw:sub(1, i), "raw chain must not lose or duplicate keys")
  assert(target:sub(1, #ctx.committed) == ctx.committed, "every automatic commit must match the target")
end
assert(ctx.committed == target:sub(1, #target - #"控制"), "long sentence must continue committing after learning")
assert(ctx.input == "ueuqrp", "the final unconfirmed word must remain editable")
assert(learning_updates == #commits and learning_updates > 1, "every automatic commit must reach online learning")
assert(translator_env._tiger_user_model_commits == #commits)
local yielded = {}
Candidate = function(kind, start, finish, text, comment)
  return { type = kind, start = start, _end = finish, text = text, comment = comment }
end
yield = function(candidate) yielded[#yielded + 1] = candidate end
local seg = { start = 0, _end = #ctx.input, has_tag = function() return true end }
native.translator.func(ctx.input, seg, translator_env)
assert(yielded[1] and ctx.committed .. yielded[1].text == target,
    "the real translator must trim committed text and return the correct suffix")
-- Avoid persisting the deliberately isolated test learner.
translator_env._tiger_user_model_dirty = false
native.translator.fini(translator_env)
proc._test.reset()
print(string.format("online early-commit regression passed (%s): %d commits, pending=%s, %.1fms/key",
    mode, #commits, yielded[1].text, (os.clock() - started) * 1000 / #raw))
