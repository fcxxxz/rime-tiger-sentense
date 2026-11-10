-- Independent TSC1 compact-vs-legacy ABI regression over the real Tiger V5 assets.
-- This test creates only in-memory engine state and never touches a user snapshot.
local root = arg[1] or "."
local baseline_root = arg[2]
package.path = root .. "/tiger_sentence_native/?.lua;" .. root .. "/lua/?.lua;" .. package.path
local lib = root .. "/tiger_sentence_native/libtigerengine.dylib"
local model = root .. "/tiger_sentence_native/mohu-sentence-ngram-v5.bin"
local lexicon = root .. "/tiger_sentence_native/data/tiger/tiger.lexicon.txt"

local function load_api(path)
  local loader, err = package.loadlib(path, "luaopen_tigerengine")
  assert(loader, "loadlib " .. path .. ": " .. tostring(err))
  return loader()
end

local api = load_api(lib)
assert(type(api.create) == "function", "native create is missing")
assert(type(api.decode) == "function", "native decode is missing")
assert(type(api.decode_static) == "function", "legacy static decode is missing")
assert(type(api.decode_static_compact) == "function",
  "new decode_static_compact ABI is missing")

local handle, create_err = api.create(model, lexicon, 200, 0)
assert(handle, "create failed: " .. tostring(create_err))

local function u32(data, pos)
  local value
  value, pos = string.unpack("<I4", data, pos)
  return value, pos
end

local function rounded_legacy_number(value)
  return tonumber(string.format("%.9g", value))
end

local function parse_legacy(output)
  assert(type(output) == "string", "legacy output is not a string")
  local lines = {}
  for line in (output .. "\n"):gmatch("(.-)\n") do
    lines[#lines + 1] = line
  end
  assert(#lines >= 1, "legacy output has no header")
  local header = {}
  for field in lines[1]:gmatch("%S+") do header[#header + 1] = tonumber(field) end
  assert(#header == 10, "legacy header field count: " .. #header)
  local result = {
    truncated = header[1] == 1,
    early_truncated = header[2] == 1,
    uses_incomplete = header[3] == 1,
    prefers_incomplete = header[4] == 1,
    n_final = header[5],
    n_early = header[6],
    consensus_complete = header[7] == 1,
    consensus_text_bytes = header[8],
    consensus_raw_length = header[9],
    visible_consensus = header[10] == 1,
    items = {},
    early = {},
  }
  local expected = result.n_final + result.n_early
  local seen = 0
  for i = 2, #lines do
    local line = lines[i]
    if line ~= "" then
      local text, segmented, score, confidence, max_rank, pathmap, personal, learning =
        line:match("^([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)\t(.*)\t([01])\t([01])$")
      assert(text, "malformed legacy row: " .. line)
      local lengths = {}
      for text_bytes, raw_length in pathmap:gmatch("(%d+):(%d+)") do
        lengths[tonumber(text_bytes)] = tonumber(raw_length)
      end
      local item = {
        text = text,
        segmented = segmented,
        score = tonumber(score),
        confidence = tonumber(confidence),
        max_rank = tonumber(max_rank),
        raw_lengths = lengths,
        personal = personal == "1",
        learning_affected = learning == "1",
      }
      seen = seen + 1
      local target = seen <= result.n_final and result.items or result.early
      target[#target + 1] = item
    end
  end
  assert(seen == expected,
    string.format("legacy row count %d != header %d", seen, expected))
  return result
end

local function parse_compact(output)
  assert(type(output) == "string", "compact output is not a string")
  assert(#output >= 28 and output:sub(1, 4) == "TSC1",
    "compact magic/size is invalid")
  local size, flags, n_final, n_early, consensus_bytes, consensus_raw, pos =
    string.unpack("<I4I4I4I4I4I4", output, 5)
  assert(size == #output, string.format("compact size %d != %d", size, #output))
  assert(flags <= 63, "compact flags outside v1 mask")
  local result = {
    truncated = flags & 1 ~= 0,
    early_truncated = flags & 2 ~= 0,
    uses_incomplete = flags & 4 ~= 0,
    prefers_incomplete = flags & 8 ~= 0,
    consensus_complete = flags & 16 ~= 0,
    visible_consensus = flags & 32 ~= 0,
    n_final = n_final,
    n_early = n_early,
    consensus_text_bytes = consensus_bytes,
    consensus_raw_length = consensus_raw,
    items = {},
    early = {},
  }
  for index = 1, n_final + n_early do
    local text_bytes, cuts, row_flags, confidence
    text_bytes, cuts, row_flags, confidence, pos =
      string.unpack("<I4I4I4d", output, pos)
    assert(text_bytes > 0, "compact row has empty text")
    assert(row_flags <= 3, "compact row flags outside v1 mask")
    assert(confidence == confidence and confidence ~= math.huge and confidence ~= -math.huge,
      "compact confidence is non-finite")
    local text = output:sub(pos, pos + text_bytes - 1)
    assert(#text == text_bytes, "compact row text is truncated")
    pos = pos + text_bytes
    local lengths = {}
    for _ = 1, cuts do
      local bytes, raw_length
      bytes, raw_length, pos = string.unpack("<I4I4", output, pos)
      assert(bytes <= text_bytes, "compact boundary exceeds text bytes")
      assert(lengths[bytes] == nil, "duplicate compact boundary")
      lengths[bytes] = raw_length
    end
    local item = {
      text = text,
      confidence = confidence,
      raw_lengths = lengths,
      personal = row_flags & 1 ~= 0,
      learning_affected = row_flags & 2 ~= 0,
    }
    local target = index <= n_final and result.items or result.early
    target[#target + 1] = item
  end
  assert(pos == #output + 1, "compact output has trailing bytes")
  return result
end

local function assert_same_map(expected, actual, label)
  local expected_count, actual_count = 0, 0
  for bytes, raw_length in pairs(expected) do
    expected_count = expected_count + 1
    assert(actual[bytes] == raw_length,
      string.format("%s boundary %s: %s != %s", label, bytes, raw_length, actual[bytes]))
  end
  for _ in pairs(actual) do actual_count = actual_count + 1 end
  assert(expected_count == actual_count,
    string.format("%s boundary count %d != %d", label, actual_count, expected_count))
end

local function assert_equivalent(raw, label)
  local before = assert(api.decode(handle, raw, false))
  local legacy_output = assert(api.decode_static(handle, raw))
  local compact_output = assert(api.decode_static_compact(handle, raw))
  local legacy = parse_legacy(legacy_output)
  local compact = parse_compact(compact_output)

  for _, field in ipairs({
    "truncated", "early_truncated", "uses_incomplete", "prefers_incomplete",
    "consensus_complete", "visible_consensus", "n_final", "n_early",
    "consensus_text_bytes", "consensus_raw_length",
  }) do
    assert(legacy[field] == compact[field],
      string.format("%s %s differs: %s != %s", label, field,
        tostring(legacy[field]), tostring(compact[field])))
  end
  for _, list_name in ipairs({ "items", "early" }) do
    local left, right = legacy[list_name], compact[list_name]
    assert(#left == #right, string.format("%s %s count differs", label, list_name))
    for i = 1, #left do
      local a, b = left[i], right[i]
      assert(a.text == b.text,
        string.format("%s %s[%d] text differs: %q != %q", label, list_name, i,
          a.text, b.text))
      assert(rounded_legacy_number(a.confidence) == b.confidence,
        string.format("%s %s[%d] confidence differs: %.17g != %.17g", label,
          list_name, i, rounded_legacy_number(a.confidence), b.confidence))
      assert_same_map(a.raw_lengths, b.raw_lengths,
        string.format("%s %s[%d] raw_lengths", label, list_name, i))
      assert(a.personal == b.personal,
        string.format("%s %s[%d] personal differs", label, list_name, i))
      assert(a.learning_affected == b.learning_affected,
        string.format("%s %s[%d] learning_affected differs", label, list_name, i))
    end
  end

  local after = assert(api.decode(handle, raw, false))
  assert(before == after, label .. " compact call changed ordinary decode bytes")
  return #legacy.items, #legacy.early
end

local function mutate(label, fn)
  local ok, err = pcall(fn)
  assert(ok, label .. " failed: " .. tostring(err))
end

-- Explicitly exercise the requested configuration APIs when present.
assert(api.set_two_char_word_gate and api.set_two_char_word_gate(handle, 0),
  "set_two_char_word_gate(false) failed")
assert(api.set_learning_context_guard and api.set_learning_context_guard(handle, 1),
  "set_learning_context_guard(true) failed")

local raw_seed = "dukgrkauxdgafmakmnfkke"
local raws = {}
for i = 1, #raw_seed do raws[#raws + 1] = raw_seed:sub(1, i) end
-- Add explicit code and boundary shapes, including a long Chinese-producing input.
for _, raw in ipairs({
  "aa", "aabh", "aabj", "aapm", "abte", "abxn", "dukgrk", "dukgrkaux",
  "dgaf", "makm", "nfkke", "dukgrkauxdgafmakmnfkke",
}) do raws[#raws + 1] = raw end
for i = #raw_seed, 1, -1 do raws[#raws + 1] = raw_seed:sub(1, i) end
assert(#raws >= 50, "query corpus is too small")

local total_queries, total_final, total_early = 0, 0, 0
local function query(raw, label)
  local finals, early = assert_equivalent(raw, label)
  total_queries = total_queries + 1
  total_final = total_final + finals
  total_early = total_early + early
end

-- Append, repeat, and backspace-style raw queries.
for i, raw in ipairs(raws) do
  query(raw, "raw-step-" .. i)
  if i == 8 then
    mutate("personal lexicon install", function()
      assert(api.set_personal_lexicon(handle, "dukgrk\t无法\t3\n") == nil)
    end)
  elseif i == 16 then
    mutate("personal adjustment +1", function()
      assert(api.adjust_personal(handle, "dukgrk", "无法", 1) >= 0)
    end)
  elseif i == 24 then
    mutate("user model update", function()
      assert(api.update_user_model(handle, "无法") >= 0)
    end)
  elseif i == 32 then
    mutate("decode context set", function()
      assert(api.set_decode_context(handle, "他说：无法编辑。", 2) >= 0)
    end)
  elseif i == 40 then
    mutate("personal adjustment +2", function()
      assert(api.adjust_personal(handle, "dukgrk", "无法", 2) >= 0)
    end)
  elseif i == 48 then
    mutate("personal adjustment +3", function()
      assert(api.adjust_personal(handle, "dukgrk", "无法", 3) >= 0)
    end)
  end
end

-- State changes after the corpus: context clear, another update, and repeated raws.
mutate("decode context clear", function()
  assert(api.set_decode_context(handle, "", 2) >= 0)
end)
mutate("second user model update", function()
  assert(api.update_user_model(handle, "编辑") >= 0)
end)
for i = 1, 12 do
  local raw = raws[((i * 7 - 1) % #raws) + 1]
  query(raw, "repeat-after-mutation-" .. i)
end

-- Invalid parameters must fail safely through the Lua ABI without corrupting the handle.
local ok, err = pcall(api.decode_static_compact, handle, string.rep("a", 129))
assert(ok and err == nil, "overlong compact raw must return nil/error tuple")
local invalid_output, invalid_error = api.decode_static_compact(-1, "aa")
assert(invalid_output == nil and type(invalid_error) == "string",
  "invalid handle must return nil and an error")
query("dukgrk", "post-invalid-parameter")

api.free(handle)

-- Exercise the production TSC1 parser directly.  The parser is local by design;
-- debug upvalues let this regression feed malformed protocol bytes without
-- replacing production code or invoking the native decoder.
local sentence = require("mohu_tiger_sentence")
local parse_static_compact
for index = 1, 64 do
  local name, value = debug.getupvalue(sentence.decode_static_with_early, index)
  if not name then break end
  if name == "parse_static_compact" then
    parse_static_compact = value
    break
  end
end
assert(type(parse_static_compact) == "function",
  "production parse_static_compact upvalue is unavailable")

local function compact_payload(options)
  options = options or {}
  local rows = options.rows or {}
  local body = {}
  for _, row in ipairs(rows) do
    local boundaries = row.boundaries or {}
    body[#body + 1] = string.pack("<I4I4I4d", #row.text, #boundaries,
      row.flags or 0, row.confidence or 0.5)
    body[#body + 1] = row.text
    for _, boundary in ipairs(boundaries) do
      body[#body + 1] = string.pack("<I4I4", boundary[1], boundary[2])
    end
  end
  local payload = table.concat(body)
  local flags = options.flags or 0
  local n_final = options.n_final
  if n_final == nil then n_final = #rows end
  local n_early = options.n_early or 0
  local size = 28 + #payload
  return "TSC1" .. string.pack("<I4I4I4I4I4I4", size, flags,
    n_final, n_early, options.consensus_bytes or 0,
    options.consensus_raw or 0) .. payload
end

local malformed_cases = 0
local function reject_compact(label, payload, canonical_raw)
  local ok, parsed = pcall(parse_static_compact, payload, canonical_raw or "aabb")
  assert(ok and parsed == nil,
    label .. " was accepted by production parser")
  malformed_cases = malformed_cases + 1
end

local valid_row = {
  text = "甲乙", confidence = 0.5,
  boundaries = { { 3, 2 }, { 6, 4 } },
}
local valid_compact = compact_payload({
  rows = { valid_row }, flags = 16, consensus_bytes = 3,
  consensus_raw = 2,
})
assert(parse_static_compact(valid_compact, "aabb") ~= nil,
  "well-formed compact fixture was rejected")

-- Text payload validation: malformed UTF-8, NUL, control bytes, tab, and LF.
reject_compact("invalid utf8", compact_payload({ rows = {
  { text = "\xc0\x80", boundaries = { { 2, 2 } } },
} }))
for label, text in pairs({
  ["NUL"] = "甲\0乙",
  ["tab"] = "甲\t乙",
  ["LF"] = "甲\n乙",
  ["control"] = "甲\1乙",
}) do
  reject_compact(label, compact_payload({ rows = {
    { text = text, boundaries = { { #text, 2 } } },
  } }))
end

-- Consensus metadata is only legal when the complete bit is set, and both
-- byte domains are strict prefixes of the selected candidate/raw input.
reject_compact("consensus omitted flag", compact_payload({
  rows = { valid_row }, consensus_bytes = 3, consensus_raw = 2,
}), "aabb")
reject_compact("consensus text bound", compact_payload({
  rows = { valid_row }, flags = 16, consensus_bytes = #valid_row.text,
  consensus_raw = 2,
}), "aabb")
reject_compact("consensus raw bound", compact_payload({
  rows = { valid_row }, flags = 16, consensus_bytes = 3,
  consensus_raw = #"aabb",
}), "aabb")
reject_compact("consensus without source", compact_payload({
  flags = 16, consensus_bytes = 3, consensus_raw = 2,
}), "aabb")

-- Confidence must be finite; row flags and top-level flags are closed sets.
for label, confidence in ipairs({ 0 / 0, math.huge, -math.huge }) do
  reject_compact("non-finite confidence " .. label, compact_payload({ rows = {
    { text = "甲", confidence = confidence, boundaries = { { 3, 2 } } },
  } }))
end
reject_compact("unknown top-level flags", compact_payload({
  rows = { valid_row }, flags = 64,
}))
-- Mutate the row flags after packing so this case reaches the row validator.
do
  local malformed = valid_compact:sub(1, 36) .. string.pack("<I4", 4) ..
    valid_compact:sub(41)
  reject_compact("unknown row flags", malformed)
end

-- Header/row count mismatch and every byte truncation of a size-consistent
-- payload must fail closed.  Rewriting the size makes each cut exercise the
-- parser's actual boundary checks rather than only the size check.
do
  local count_wrong = compact_payload({ rows = { valid_row }, n_final = 2 })
  reject_compact("final count mismatch", count_wrong)
  local trailing_row = compact_payload({ rows = { valid_row }, n_final = 0 })
  reject_compact("zero count with row bytes", trailing_row)
  for cut = 0, #valid_compact - 1 do
    local prefix = valid_compact:sub(1, cut)
    if cut >= 8 then
      prefix = prefix:sub(1, 4) .. string.pack("<I4", cut) .. prefix:sub(9)
    end
    reject_compact("truncation at byte " .. cut, prefix)
  end
end

-- Duplicate candidate text is forbidden within either final or early list.
local duplicate_final = compact_payload({
  rows = { valid_row, valid_row }, n_final = 2,
})
reject_compact("duplicate final text", duplicate_final)
local duplicate_early = compact_payload({
  rows = { valid_row, valid_row }, n_final = 0, n_early = 2,
})
reject_compact("duplicate early text", duplicate_early)

-- Boundary offsets are text-byte positions and must stay within the row text.
reject_compact("boundary exceeds text", compact_payload({ rows = {
  { text = "甲", boundaries = { { 4, 2 } } },
} }))
reject_compact("empty text", compact_payload({ rows = { { text = "" } } }))
reject_compact("bad magic", "BAD!" .. valid_compact:sub(5))
reject_compact("size mismatch", valid_compact .. "\0")
reject_compact("early count mismatch", compact_payload({
  rows = { valid_row }, n_final = 0, n_early = 2,
}))
-- The same text may appear once in each independent list.
assert(parse_static_compact(compact_payload({
  rows = { valid_row, valid_row }, n_final = 1, n_early = 1,
}), "aabb"), "equal text across final/early lists is valid")
print(string.format("production TSC1 parser passed: %d malformed cases rejected", malformed_cases))

-- The supplied baseline is optional and must be passed explicitly as arg[2].
-- Without it, skip the old-ABI probe so this regression stays portable.
if baseline_root then
  local baseline_lib = baseline_root .. "/tiger_sentence_native/libtigerengine.dylib"
  local baseline_model = baseline_root .. "/tiger_sentence_native/mohu-sentence-ngram-v5.bin"
  local baseline_lexicon = baseline_root .. "/tiger_sentence_native/data/tiger/tiger.lexicon.txt"
  local baseline_loader = package.loadlib(baseline_lib, "luaopen_tigerengine")
  if baseline_loader then
    local old = baseline_loader()
    assert(type(old.decode_static) == "function", "baseline lacks legacy static decode")
    assert(old.decode_static_compact == nil,
      "baseline unexpectedly exports decode_static_compact")
    local old_handle, old_err = old.create(baseline_model, baseline_lexicon, 200, 0)
    assert(old_handle, "baseline create failed: " .. tostring(old_err))
    local old_output = assert(old.decode_static(old_handle, "dukgrkauxdgaf"))
    assert(type(old_output) == "string" and #old_output > 0,
      "baseline legacy static decode returned no bytes")
    old.free(old_handle)
    print("baseline old ABI fallback: legacy decode_static usable; compact absent")
  else
    print("baseline old ABI fallback: baseline dylib not loadable; skipped")
  end
else
  print("baseline old ABI fallback: skipped (pass baseline root as arg[2])")
end

print(string.format("TSC1 compact equivalence passed: %d queries, %d final rows, %d early rows",
  total_queries, total_final, total_early))
