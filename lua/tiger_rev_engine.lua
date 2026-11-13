-- 虎码方案 ` 反查的模型解码器（tiger_rev_engine）。
--
-- 2026-11-12 架构切换：反查不再走词库（table/script translator 的精确码、
-- completion、组句语义各有坑——词库路线三连修：基础码表每字唯一精确码
-- 查不到同音字 → 音节表无组句 → Ctrl+R 探测错表），改为直接复用主输入
-- 的 libtigerengine：反查段码流喂 decode_static（纯静态、无用户学习污染），
-- 引擎组句候选原样上屏，虎码注释由 rev_tiger_comment 照加。
--
-- 码式（tiger_reverse_mode 的 rev_flypy/rev_full option）：
--   zrm（默认）——码流直接喂 zrm lexicon 的引擎；
--   flypy       ——码流直接喂 flypy lexicon 的引擎；
--   pinyin      ——全拼串先贪心切音节（tiger_rev_syllables 数据模块，
--                 build_rev_dicts.py 数据驱动学出），转 zrm 码流再解码，
--                 复用 zrm 引擎（模型是字元三元，方案间共享）。
--
-- 候选 quality 落在对应码式质量带内（1001/2001/3001），由
-- tiger_reverse_mode 的 gate 放行本码式候选。
--
-- 引擎/模型/词表缺席时安静返回（反查空，不影响主输入）。
local runtime = require("mohu_runtime")
local syllables = require("tiger_rev_syllables")

local M = { translator = {} }

local QUALITY = { zrm = 1001.0, flypy = 2001.0, pinyin = 3001.0 }
local BEAM = 200
local MAX_CANDIDATES = 10

local handles = {}      -- scheme → engine handle
local engine_module     -- tigerengine 表
local load_attempted = false

local function load_engine_module()
  if load_attempted then return engine_module end
  load_attempted = true
  local paths = runtime.paths()
  local preload = package and package.preload and package.preload["tigerengine"]
  local ok, loader
  if type(preload) == "function" then
    ok, loader = true, preload
  else
    ok, loader = pcall(package.loadlib, paths.engine, "luaopen_tigerengine")
  end
  if ok and loader then
    local m_ok, mod = pcall(loader)
    if m_ok and type(mod) == "table" and type(mod.create) == "function"
        and type(mod.decode_static) == "function" then
      engine_module = mod
    end
  end
  return engine_module
end

local function engine_handle(scheme)
  if handles[scheme] then return handles[scheme] end
  local mod = load_engine_module()
  if not mod then return nil end
  local paths = runtime.paths()
  local lexicon = paths.lexicons[scheme]
  if not lexicon then return nil end
  local probe = io.open(lexicon, "r")
  if not probe then return nil end
  probe:close()
  local ok, h = pcall(mod.create, paths.ngram, lexicon, BEAM, 1)
  if ok and h then
    handles[scheme] = h
    return h
  end
  return nil
end

-- 全拼音节表按长度降序（贪心最长匹配用）。
local zrm_syllable_lengths = {}
for syl in pairs(syllables.zrm) do
  local len = #syl
  if not zrm_syllable_lengths[len] then zrm_syllable_lengths[len] = {} end
  zrm_syllable_lengths[len][#zrm_syllable_lengths[len] + 1] = syl
end
local zrm_max_len = 0
for len in pairs(zrm_syllable_lengths) do
  if len > zrm_max_len then zrm_max_len = len end
end
local sorted_lengths = {}
for len in pairs(zrm_syllable_lengths) do sorted_lengths[#sorted_lengths + 1] = len end
table.sort(sorted_lengths, function(a, b) return a > b end)

-- 全拼串 → zrm 码流。' 为用户手动音节分隔（ni'hao），段内贪心最长音节。
-- 切不出的串返回 nil（候选静默为空，与词库反查「查无此码」行为一致）。
local function pinyin_to_zrm(code)
  local out = {}
  for chunk in code:gmatch("[^']+") do
    local index = 1
    while index <= #chunk do
      local matched = nil
      for _, len in ipairs(sorted_lengths) do
        if index + len - 1 > #chunk then
          -- 超界长度跳过
        elseif len == 1 then
          local syl = chunk:sub(index, index)
          if syllables.zrm[syl] then matched = syl break end
        else
          local syl = chunk:sub(index, index + len - 1)
          if syllables.zrm[syl] then matched = syl break end
        end
      end
      if not matched then return nil end
      out[#out + 1] = syllables.zrm[matched]
      index = index + #matched
    end
  end
  return table.concat(out)
end

-- decode_static 输出：header 一行（数字空格串）+ 候选行 text\t…。
-- 只取 text（引擎行序即分序），弱校验首行形态。
local function decode_texts(h, code)
  local ok, out = pcall(engine_module.decode_static, h, code, false)
  if not ok or type(out) ~= "string" or #out == 0 then return nil end
  local first = true
  local texts = {}
  for line in out:gmatch("([^\n]*)\n") do
    if first then
      if not line:match("^%d+ %d+ ") then return nil end
      first = false
    else
      local text = line:match("^([^\t]+)\t")
      if text and #texts < MAX_CANDIDATES then texts[#texts + 1] = text end
    end
  end
  return texts
end

-- librime-lua 的 Segment 没有 has_tag 方法（旧版亦然），用 tags 表遍历
-- （对齐 mohu.lua 的 segment_is_reverse_lookup 写法）。
local function seg_is_reverse_lookup(seg)
  if not seg or not seg.tags then return false end
  for tag in pairs(seg.tags) do
    if tag == "reverse_lookup" then return true end
  end
  return false
end

function M.translator.func(input, seg, env)
  if not seg_is_reverse_lookup(seg) then return end
  local ctx = env.engine.context
  local raw = type(ctx.input) == "string" and ctx.input or ""
  if raw:sub(1, 1) ~= "`" then return end
  local code = raw:sub(2):gsub("'$", "")
  if code == "" or code:find("[^a-z']") then return end

  local scheme = "zrm"
  if ctx.get_option and ctx:get_option("rev_full") then
    scheme = "pinyin"
  elseif ctx.get_option and ctx:get_option("rev_flypy") then
    scheme = "flypy"
  end

  local handle_scheme = scheme == "pinyin" and "zrm" or scheme
  if scheme == "pinyin" then
    local converted = pinyin_to_zrm(code)
    if not converted or converted == "" then return end
    code = converted
  end

  local h = engine_handle(handle_scheme)
  if not h then return end
  local texts = decode_texts(h, code)
  if not texts then return end
  local quality = QUALITY[scheme]
  for _, text in ipairs(texts) do
    local cand = Candidate("rev_engine", seg.start, seg._end, text, "")
    cand.quality = quality
    yield(cand)
  end
end

M._test = {
  pinyin_to_zrm = pinyin_to_zrm,
  quality = QUALITY,
}

return M
