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
-- 与 tiger_reverse_mode 的 MODES tip 文案同款（空反查码的提示候选）。
local MODE_TIP = {
  zrm = "〔反查·自然码｜Ctrl+R 切小鹤〕",
  flypy = "〔反查·小鹤｜Ctrl+R 切全拼〕",
  pinyin = "〔反查·全拼｜Ctrl+R 切双拼〕",
}
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

-- 全拼串 → 全部合法切分的 zrm 码流（DAG 记忆化枚举）。贪心最长单切分在
-- 连续全拼上系统性出错（jidangeng 切 ji+dang+eng 而非 ji+dan+geng），
-- 歧义交给引擎：全部切分并行解码、按路径置信合并。' 为用户手动音节
-- 分隔（段内仍枚举，段间笛卡尔）。
-- 容错：段尾切不出（打字中间态，如 jidangengx 的 x / nid 的 d）时退到
-- 最长合法前缀的切分，非法尾丢弃——上一个合法态的候选不闪断。
local MAX_STREAMS = 8

local function chunk_streams(chunk, upto, memo)
  upto = upto or #chunk
  memo = memo or {}
  local function cut_from(pos)
    if memo[pos] then return memo[pos] end
    local result = {}
    if pos > upto then
      result[1] = ""
    else
      for len = 1, math.min(6, upto - pos + 1) do
        local syl = chunk:sub(pos, pos + len - 1)
        local mapped = syllables.zrm[syl]
        if mapped then
          for _, tail in ipairs(cut_from(pos + len)) do
            result[#result + 1] = mapped .. tail
            if #result >= MAX_STREAMS then break end
          end
        end
        if #result >= MAX_STREAMS then break end
      end
    end
    memo[pos] = result
    return result
  end
  return cut_from(1)
end

-- 段枚举：全串无解时找最长合法前缀（可达性：cut_from(1) 空 → 从尾扫
-- 每个断点 pos-1 使 [pos..end] 有一个音节起头？直接按前缀长度递减试）。
local function chunk_streams_tolerant(chunk)
  local out = chunk_streams(chunk)
  if #out > 0 then return out end
  for prefix = #chunk - 1, 1, -1 do
    local trimmed = chunk_streams(chunk, prefix)
    if #trimmed > 0 then return trimmed end
  end
  return {}
end

local function pinyin_streams(code)
  local streams = { "" }
  for chunk in code:gmatch("[^']+") do
    local chunk_out = chunk_streams_tolerant(chunk)
    if #chunk_out == 0 then return nil end
    local merged = {}
    for _, head in ipairs(streams) do
      for _, tail in ipairs(chunk_out) do
        merged[#merged + 1] = head .. tail
        if #merged >= MAX_STREAMS then break end
      end
      if #merged >= MAX_STREAMS then break end
    end
    streams = merged
  end
  return streams
end

-- 旧名保留（单测/内部沿用）：取枚举出的第一条（最长贪心优先的次序
-- 由 DAG 枚举自然给出——len 1..6 递增，首条是最短音节贪心；无所谓，
-- 多切分全部喂引擎）。
local function pinyin_to_zrm(code)
  local streams = pinyin_streams(code)
  return streams and streams[1] or nil
end

-- decode_static 输出（include_early=true）：header 一行（10 数字字段，
-- 第 5 个 n_final 是终态行数）+ 候选行 text\tseg\tscore\tconf\t…，行序
-- 终态在前、early（未完成尾的进行态组句）在后。中间态（尾音节不全）
-- 只有 early 行——打字过程即出候选，不必打完全码。conf 为引擎路径
-- 置信，跨切分/跨终态-early 可比较。
local function decode_rows(h, code)
  local ok, out = pcall(engine_module.decode_static, h, code, true)
  if not ok or type(out) ~= "string" or #out == 0 then return nil end
  local first = true
  local rows = {}
  for line in out:gmatch("([^\n]*)\n") do
    if first then
      if not line:match("^%d+ %d+ ") then return nil end
      first = false
    else
      local text, _, _, conf = line:match("^([^\t]+)\t([^\t]*)\t([^\t]*)\t([^\t]*)")
      if text and #rows < MAX_CANDIDATES then
        rows[#rows + 1] = { text = text, conf = tonumber(conf) or 0 }
      end
    end
  end
  return rows
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

  local scheme = "zrm"
  if ctx.get_option and ctx:get_option("rev_full") then
    scheme = "pinyin"
  elseif ctx.get_option and ctx:get_option("rev_flypy") then
    scheme = "flypy"
  end

  -- 空反查码：出码式提示候选（切换后/刚进反查时候选窗首位直接可见，
  -- 敲字母即被真实候选替换）。段 prompt 通道在旧版 librime-lua 不可写、
  -- 空段无候选时 filter 也不跑——提示候选是唯一跨版本可见的通道。
  if code == "" or code:find("[^a-z']") then
    if code == "" then
      local cand = Candidate("rev_engine", seg.start, seg._end,
                             MODE_TIP[scheme], "")
      cand.quality = QUALITY[scheme]
      yield(cand)
    end
    return
  end

  local handle_scheme = scheme == "pinyin" and "zrm" or scheme
  local streams = { code }
  if scheme == "pinyin" then
    streams = pinyin_streams(code)
    if not streams then return end
  end

  -- 单音节（任一切分恰 2 键，即用户输入单音节）→ lexicon 全字枚举；
  -- 多音节 → 各切分并行喂模型组句，按路径置信合并去重。
  local rows
  if streams[1] and #streams[1] == 2 and #streams == 1 then
    local lexicon = runtime.paths().lexicons[handle_scheme]
    local texts = lexicon and lexicon_lookup(lexicon, streams[1]) or nil
    if texts then
      rows = {}
      for i, text in ipairs(texts) do rows[i] = { text = text, conf = i } end
    end
  else
    local h = engine_handle(handle_scheme)
    if not h then return end
    local merged, seen = {}, {}
    for _, stream in ipairs(streams) do
      local stream_rows = decode_rows(h, stream)
      if stream_rows then
        for _, row in ipairs(stream_rows) do
          if not seen[row.text] then
            seen[row.text] = true
            merged[#merged + 1] = row
          end
        end
      end
    end
    if #merged > 0 then
      table.sort(merged, function(a, b) return a.conf > b.conf end)
      rows = merged
    end
  end
  if not rows then return end
  local quality = QUALITY[scheme]
  local mode_name = MODE_NAME[scheme]
  local yielded = 0
  for _, row in ipairs(rows) do
    if yielded >= MAX_CANDIDATES then break end
    if row.text ~= "" then
      local codes = tiger_codes(row.text)
      local comment = codes and ("〔" .. codes .. "｜" .. mode_name .. "〕")
          or ("〔" .. mode_name .. "〕")
      local cand = Candidate("rev_engine", seg.start, seg._end, row.text, comment)
      cand.quality = quality
      yield(cand)
      yielded = yielded + 1
    end
  end
end

M._test = {
  pinyin_to_zrm = pinyin_to_zrm,
  pinyin_streams = pinyin_streams,
  quality = QUALITY,
}

return M
