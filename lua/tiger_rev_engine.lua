-- 虎码方案 ` 反查的模型解码器（tiger_rev_engine）。
--
-- 2026-11-12 架构切换：反查不再走词库（table/script translator 的精确码、
-- completion、组句语义各有坑——词库路线三连修：基础码表每字唯一精确码
-- 查不到同音字 → 音节表无组句 → Ctrl+R 探测错表），改为直接复用主输入
-- 的 libtigerengine：反查段码流喂 decode_static（纯静态、无用户学习污染），
-- 引擎组句候选原样上屏。
--
-- 码式（tiger_reverse_mode 的 rev_flypy/rev_full option）：
--   pinyin（默认）——全拼串贪心切音节（tiger_rev_syllables，数据驱动学出）
--                   转 zrm 码流，复用 zrm 引擎（字元三元模型方案间共享）；
--   zrm / flypy    ——双拼码流直接喂对应 lexicon 的引擎。
--
-- 单音节（zrm 码流恰 2 键）走 lexicon 二分枚举（全字表，reading_freq 序），
-- 多音节走模型组句；候选 quality 落码式质量带（1001/2001/3001）交 gate。
-- 候选注释由本模块直注「〔虎码｜码式名〕」（reverse_lookup_filter 对
-- lua 候选不注且码式名兼作切换提示，与前端 librime 版本无关）。
--
-- handle 创建（17M lexicon 解析 ~1.6s）在 init 预建两个——落在方案装载期，
-- 首次反查按键零等待；引擎/模型/词表缺席时安静返回（反查空）。
local runtime = require("mohu_runtime")
local syllables = require("tiger_rev_syllables")

local M = { translator = {} }

local QUALITY = { zrm = 1001.0, flypy = 2001.0, pinyin = 3001.0 }
local MODE_NAME = { zrm = "自然码", flypy = "小鹤", pinyin = "全拼" }
local BEAM = 200
local MAX_CANDIDATES = 20   -- 多音节组句候选上限（单音节走 lexicon 枚举）
local MAX_ENUM = 50         -- 单音节同码字枚举上限（防御；gj=27、ni=23）

local handles = {}      -- scheme → engine handle
local engine_module     -- tigerengine 表
local load_attempted = false
local rev_db            -- ReverseLookup("tiger.extended")（虎码注释直注）

-- 虎码注释直注：ReverseLookup 对 lua 候选不可靠（实机 reverse_lookup_filter
-- 不注），按字查码拼接；整句候选逐字连注。库缺席时注释只带码式名。
local function utf8_chars_of(text)
  local chars = {}
  local index = 1
  while index <= #text do
    local byte = text:byte(index)
    local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
    chars[#chars + 1] = text:sub(index, index + width - 1)
    index = index + width
  end
  return chars
end

local function utf8_len(text)
  return #utf8_chars_of(text)
end

local function tiger_codes(text)
  if rev_db and type(text) == "string" then
    local codes = {}
    for _, ch in ipairs(utf8_chars_of(text)) do
      local ok, code = pcall(rev_db.lookup, rev_db, ch)
      if ok and type(code) == "string" and code ~= "" then
        codes[#codes + 1] = code
      end
    end
    if #codes == utf8_len(text) and #codes > 0 then
      return table.concat(codes, " ")
    end
  end
  return nil
end

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

-- 单音节枚举：lexicon 是引擎数据文件（非 Rime 词库），按码字典序排序，
-- 二分定位后行序即 rank 序（同码全字表，gj=干感敢赶甘…27 字）。反查的
-- 「查字」场景（`gan 找全音字）由枚举供全；模型解码给组句（多音节），
-- 其 beam 视图天然只含最优路径——单音节枚举补齐，两场景各取所长。
local function lexicon_lookup(lexicon_path, code)
  local f = io.open(lexicon_path, "r")
  if not f then return nil end
  local size = f:seek("end")
  if not size or size == 0 then f:close() return nil end

  -- 读 pos 起的一整行（pos>0 先跳残行）
  local function read_line(pos)
    f:seek("set", pos)
    if pos > 0 then f:read("*l") end
    return f:read("*l")
  end

  -- 二分下界：第一个 code 列 >= 目标码 的行位置
  local lo, hi = 0, size
  while lo < hi do
    local mid = math.floor((lo + hi) / 2)
    local line = read_line(mid)
    local row_code = line and (line:match("^[^\t]*")) or ""
    if row_code < code then
      lo = mid + 1
    else
      hi = mid
    end
  end
  -- 行序是 lexicon rank（全码表序，多音字挂载如 呢@ni rank1 而读音频次
  -- 仅 1）；反查按读音频次（第 5 列 reading_freq）降序——你 尼 泥…而非
  -- 呢 你 尼。
  local rows, seen = {}, {}
  local pos = lo
  while #rows < MAX_ENUM do
    local line = read_line(pos)
    if not line then break end
    pos = pos + #line + 1
    local row_code = line:match("^[^\t]*")  -- 永不 nil（短行兜底空串）
    if row_code == code then
      local text, _, _, freq =
          line:match("^[^\t]*\t([^\t]*)\t([^\t]*)\t([^\t]*)\t([^\t]*)")
      if text and text ~= "" and not seen[text] then
        seen[text] = true
        rows[#rows + 1] = { text = text, freq = tonumber(freq) or 0 }
      end
    elseif row_code > code then
      break
    end
  end
  f:close()
  if #rows == 0 then return nil end
  table.sort(rows, function(a, b) return a.freq > b.freq end)
  local texts = {}
  for i, row in ipairs(rows) do texts[i] = row.text end
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

function M.translator.init(env)
  -- handle 创建是 17M lexicon 文本解析（实测 ~1.6s/个），懒建会卡在首次
  -- 反查按键上——装载期预建 zrm+flypy 两个（全拼复用 zrm），打字路径
  -- 零等待；缺席环境（无 dylib/模型）安静跳过。
  pcall(engine_handle, "zrm")
  pcall(engine_handle, "flypy")
  -- 虎码注释库（tiger.extended.reverse.bin，装机已有）；缺席时注释退化为
  -- 仅码式名。
  if type(ReverseLookup) == "function" then
    local ok, db = pcall(ReverseLookup, "tiger.extended")
    if ok and db and type(db.lookup) == "function" then rev_db = db end
  end
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

  -- 单音节（zrm 码流恰 2 键）→ lexicon 全字枚举；多音节 → 模型组句。
  local texts
  if #code == 2 then
    local lexicon = runtime.paths().lexicons[handle_scheme]
    texts = lexicon and lexicon_lookup(lexicon, code) or nil
  else
    local h = engine_handle(handle_scheme)
    if not h then return end
    texts = decode_texts(h, code)
  end
  if not texts or #texts == 0 then return end
  local quality = QUALITY[scheme]
  local mode_name = MODE_NAME[scheme]
  for _, text in ipairs(texts) do
    local codes = tiger_codes(text)
    local comment = codes and ("〔" .. codes .. "｜" .. mode_name .. "〕")
        or ("〔" .. mode_name .. "〕")
    local cand = Candidate("rev_engine", seg.start, seg._end, text, comment)
    cand.quality = quality
    yield(cand)
  end
end

M._test = {
  pinyin_to_zrm = pinyin_to_zrm,
  quality = QUALITY,
}

return M
