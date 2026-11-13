-- 虎码整句模式处理器（tiger_mode_proc）
--
-- ① 整句模式字母接管：整句开（sentence 选项，默认开）且原生引擎就绪时
-- 截获小写字母键经 push_input 自行追加输入——speller 的 max_code_length/
-- auto_clear（4 码顶功）与 auto_select 只在单字模式对字母生效，整句可
-- 无限续打。引擎不可用（宿主 Lua 失配、缺 dylib/模型，如 mira 测试宿主）
-- 或整句关时整体让位（kNoop），方案退化为纯单字顶屏——单字行为零改动。
-- ; 快符、` 反查等带非字母前缀的输入不截获；超过 128 键不再追加。
--
-- ② 提前上屏（early_commit 选项，默认开，仅整句模式）：置信度 tracker
--    规则（对齐虎整句 TigerClaw 原版 1.6 的 evidence 语义）：
--   - 每次解码用「已提交码串 + 存活码」整串（LM 左上文随码流进入）；
--   - 置信源：有 incomplete tail 时用引擎 early 行，否则终态候选行；
--     截断时以不含用户学习的独立搜索复核，证据须达强档 0.999；
--   - 前缀证据 =（前缀文本, 码长边界）二元组：前缀质量占比 ≥ 门槛
--     （默认 0.99，tiger/early_commit_threshold 可配）且边界封死（同前缀
--     行在该切点码长上 ≥0.99999 全票）才算达标；
--   - 达标前缀各建 tracker 连续计票：普通证据 3 键、强证据（占比 ≥0.999）
--     2 键即可提交；无达标键时 tracker 最多保留 3 键（不计数）；模型未
--     收敛期的分叉读法只是不形成 tracker，不会污染后续（全史公共前缀
--     会被单条分叉提案判死整句，1 万句实测 P90 未上屏 14 键）；
--   - 提交增量须与引擎可见首选前缀一致；门槛：全句 >4 键、增量 ≥1 字、
--     存活 ≥3 键；
--   - 触发即 engine:commit_text(增量文本) + clear + push_input(余码)；
--   - BackSpace 清 tracker；翻页/方向键浏览挂起本句提前上屏；整句清空
--     （空格全句上屏/Esc）重置全部状态。
-- 配置：tiger/sentence_option（默认 "sentence"）、
-- tiger/early_commit_option（默认 "early_commit"）。

local kRejected = 0 -- 拒: 不作響應, 由操作系統做默認處理
local kAccepted = 1 -- 收: 由rime響應該按鍵
local kNoop     = 2 -- 無: 請下一個processor繼續看

local M = { processor = {} }

local MAX_RAW_LENGTH = 128-- 前缀证据门槛（对齐虎整句原版：0.99 普通 / 0.999 强档 2 键 / 边界
-- 封死 0.99999 全票；其 388MB fivegram 下 82 句我方误句全零误顶，
-- 见 docs/reports/2026-10-23-early-commit-benchmark.md 与对照记录）。
local DEFAULT_SHARE = 0.99       -- 前缀质量占比门槛（可配，见 init）
local STRONG_SHARE = 0.999       -- 强证据门槛：连续 2 键即可提交
local CLOSED_BOUNDARY_SHARE = 0.99999 -- 边界封死：同前缀行切点码长全票
local REQUIRED_EVIDENCE = 3      -- 普通证据：连续 3 键
local REQUIRED_STRONG = 2        -- 强证据：连续 2 键
local MAX_NEUTRAL_GAP = 3        -- 无达标前缀时 tracker 最多保留 3 键
local MIN_TOTAL_KEYS = 4      -- 全句（含已提交）至少 >4 键才允许证据
local MIN_LIVE_KEYS = 3       -- 提交时存活码至少 3 键
local DEFAULT_PENDING_CHAR_CAP = 4  -- 未上屏字数帽（0 关闭），schema 可调

local engine_module
local engine_module_attempted = false

local function load_engine_module()
  if engine_module_attempted then return engine_module end
  engine_module_attempted = true
  local ok, module = pcall(require, "mohu_sentence")
  if ok and type(module) == "table" and type(module.native_ready) == "function" then
    engine_module = module
  end
  return engine_module
end

-- 提前上屏会话状态（模块级：跨 env 共享一个方案实例的状态）。
local early = {
  trackers = {},     -- { [前缀..码长] = {text,boundary,evidence,strong,gap} }
  last_seen_raw = "", -- 严格单键续打基准（断裂即清 tracker）
  suspended = false, -- 本句挂起（用户翻页/浏览）
  committed_text = "",
  committed_raw = "", -- 已提交的原始码串（逐次累积）
}

local function utf8_chars(text)
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

local function utf8_length(text)
  return #utf8_chars(text)
end

local function logsumexp(values)
  local peak = -math.huge
  for _, value in ipairs(values) do
    if value > peak then peak = value end
  end
  if peak == -math.huge then return peak end
  local sum = 0.0
  for _, value in ipairs(values) do
    sum = sum + math.exp(value - peak)
  end
  return peak + math.log(sum)
end

-- 行的 raw_lengths（引擎 pathmap 解析产物：{ 文本字节长 → 码长 }，
-- build_pathmap 的 text_length 是 UTF-8 字节长度）；单测的模拟行可直接
-- 给 pathmap 字符串。
local function pathmap_lengths(row)
  local lengths = {}
  for bytes, raw_len in (row.pathmap or ""):gmatch("(%d+):(%d+)") do
    lengths[tonumber(bytes)] = tonumber(raw_len)
  end
  return lengths
end

local function row_lengths(row)
  return row.raw_lengths or pathmap_lengths(row)
end

-- 按字节长度取文本前缀（路径边界只落在字符边界上）。
local function prefix_by_bytes(text, nbytes)
  local index = 1
  while index <= #text and index <= nbytes do
    local byte = text:byte(index)
    local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
    if index + width - 1 > nbytes then break end
    index = index + width
  end
  return text:sub(1, index - 1)
end

-- 前缀证据（虎整句 build_prefix_evidence 对应物）：对每个（前缀文本,
-- 码长边界）二元组计算 share=以该前缀开头的行质量占全部候选行的比例、
-- boundary_share=同前缀行中切点码长与该边界一致的比例。share ≥ 门槛且
-- 边界封死（≥CLOSED_BOUNDARY_SHARE）才算达标。可见行是 200 态束的有界
-- 视图，此处的边界全票是原版全束证明的近似；误判由连续计票吸收。
local function build_prefix_evidence(rows, raw_length, threshold)
  threshold = threshold or DEFAULT_SHARE
  if not rows or #rows == 0 then return nil end
  local masses = {}
  for i, row in ipairs(rows) do masses[i] = row.confidence end
  local total = logsumexp(masses)
  if total == -math.huge then return nil end
  local prefix_masses = {}  -- 前缀文本 → { 行质量 }（每行每前缀只计一次）
  local cut_masses = {}     -- 前缀文本 \1 边界 → { 行质量 }
  local prefix_learning = {}  -- 前缀文本 → 该前缀族是否有学习污染行
  for _, row in ipairs(rows) do
    local lengths = row_lengths(row)
    -- 引擎切点通常正好落在 UTF-8 字符边界；每行只扫描一次。
    -- 非整字切点仍走原取前缀逻辑，保留模拟行及异常边界的截断语义。
    local ends = {}
    local index = 1
    while index <= #row.text do
      local byte = row.text:byte(index)
      local width = byte < 0x80 and 1 or byte < 0xE0 and 2 or byte < 0xF0 and 3 or 4
      index = index + width
      ends[index - 1] = true
    end
    local counted = {}
    for bytes, boundary in pairs(lengths) do
      if type(bytes) == "number" and bytes > 0 then
        local valid_boundary = type(boundary) == "number"
            and boundary > 0 and boundary <= raw_length
        if valid_boundary or row.learning_affected then
          local prefix = ends[bytes] and row.text:sub(1, bytes)
              or prefix_by_bytes(row.text, bytes)
          if prefix ~= "" then
            -- 学习污染也覆盖超出 raw_length 或无效码长的切点。
            if row.learning_affected then prefix_learning[prefix] = true end
            if valid_boundary and not counted[prefix] then
              counted[prefix] = true
              local list = prefix_masses[prefix]
              if list then list[#list + 1] = row.confidence
              else prefix_masses[prefix] = { row.confidence } end
              local key = prefix .. "\1" .. boundary
              local clist = cut_masses[key]
              if clist then clist[#clist + 1] = row.confidence
              else cut_masses[key] = { row.confidence } end
            end
          end
        end
      end
    end
  end
  local qualifying = {}
  local prefix_mass_cache = {}
  for key, clist in pairs(cut_masses) do
    local prefix, digits = key:match("^(.-)\1(%d+)$")
    local pmass = prefix_mass_cache[prefix]
    if pmass == nil then
      pmass = logsumexp(prefix_masses[prefix])
      prefix_mass_cache[prefix] = pmass
    end
    local share = math.exp(pmass - total)
    if share >= threshold then
      local boundary_share = math.exp(logsumexp(clist) - pmass)
      if boundary_share >= CLOSED_BOUNDARY_SHARE then
        qualifying[#qualifying + 1] = {
          text = prefix, boundary = tonumber(digits),
          share = share,
          -- 强档证据须纯模型：前缀族含用户学习增益行（调频融合/个人词
          -- boost）时降级为普通证据（虎整 base_share ≥ strong 同款约束，
          -- learned paths must not authorize early commit）。
          strong = share >= STRONG_SHARE and not prefix_learning[prefix],
        }
      end
    end
  end
  table.sort(qualifying, function(a, b)
    if a.boundary ~= b.boundary then return a.boundary < b.boundary end
    return #a.text < #b.text
  end)
  return qualifying
end

-- 无达标前缀的键：tracker 计 gap 不计证据，超过 MAX_NEUTRAL_GAP 即弃
-- （低置信闪断不立刻作废已有证据）。
local function step_gap_trackers()
  for key, tracker in pairs(early.trackers) do
    tracker.gap = tracker.gap + 1
    if tracker.gap > MAX_NEUTRAL_GAP then early.trackers[key] = nil end
  end
end

-- 成熟 tracker 提交：证据/强档达标、延伸已提交、边界合法、可见首选
-- 一致、存活 ≥3 键；多个成熟时取边界最深（相同则文本最长）者。
local function try_commit_mature(env, full_raw, visible_top)
  local selected = nil
  for _, tracker in pairs(early.trackers) do
    if (tracker.evidence >= REQUIRED_EVIDENCE or tracker.strong >= REQUIRED_STRONG)
        and tracker.boundary > #early.committed_raw
        and tracker.boundary <= #full_raw
        and #tracker.text > #early.committed_text
        and tracker.text:sub(1, #early.committed_text) == early.committed_text
        and (visible_top == nil
             or visible_top:sub(1, #tracker.text) == tracker.text) then
      if not selected or tracker.boundary > selected.boundary
          or (tracker.boundary == selected.boundary
              and #tracker.text > #selected.text) then
        selected = tracker
      end
    end
  end
  if not selected then return end
  local context = env.engine.context
  local commit = selected.text:sub(#early.committed_text + 1)
  if utf8_length(commit) < 1 or #context.input < MIN_LIVE_KEYS then return end
  early.committed_text = selected.text
  early.committed_raw = full_raw:sub(1, selected.boundary)
  -- 已提交链共享给翻译器：菜单/空格上屏的解码带此左上文（虎整同款
  -- 设计——committed-prefix state must be visible to both the processor
  -- and the translator）。落 已上屏后，菜单对尾码的组句竞争才有
  -- 落云 二元组权重，不再退化为裸尾码视角。
  if context.set_property then
    context:set_property("tiger_committed",
      early.committed_raw .. "\t" .. early.committed_text)
  end
  early.trackers = {}
  early.last_seen_raw = ""
  env.engine:commit_text(commit)
  context:clear()
  local remaining = full_raw:sub(selected.boundary + 1)
  if remaining ~= "" then context:push_input(remaining) end
end

-- 未上屏字数帽：最优候选未提交字数 > cap 时，把已提交前缀之后的
-- (pending-cap) 字强制提交。与基准 driver-cap 同款语义：取首个延伸已提交
-- 前缀的行，按 raw_lengths 找字边界截点；强制提交重置 tracker（提交链
-- 变更，旧证据失效）。帽触发的提交不经过证据门——正是证据未封边时
-- pending 才会堆高。
local function try_commit_cap(env)
  local cap = env._tiger_pending_cap or 0
  if cap <= 0 then return end
  local context = env.engine.context
  local live = context.input
  if type(live) ~= "string" or #live < cap + 1 then return end
  local module = load_engine_module()
  if not module or not module.native_ready() then return end
  if early.suspended then return end
  local full_raw = early.committed_raw .. live
  local decoded = module.decode_with_early(full_raw)
  if not decoded then return end
  -- 提交对象取终态 items（用户可见的首选），不用 early 行（内部置信视图，
  -- 排序可与可见菜单不同——实测廖哈句 early 首选是「去边去」家族而可见
  -- 首选是「劫持」，从 early 提交会把句子锁进错误家族）。
  local rows = decoded.items
  if not rows or #rows == 0 then return end
  local prefix, cr = early.committed_text, early.committed_raw
  for _, row in ipairs(rows) do
    local text = row.text
    if prefix == ""
        or (#text > #prefix and text:sub(1, #prefix) == prefix) then
      local pend = utf8_length(text) - utf8_length(prefix)
      if pend <= cap then return end
      local rl = row.raw_lengths
      if not rl then return end
      -- 截点：已提交前缀之后再走 (pend-cap) 字的结束字节
      local i, taken, cut = #prefix + 1, 0, nil
      while i <= #text and taken < pend - cap do
        local c = text:byte(i)
        i = i + (c < 0x80 and 1 or (c < 0xE0 and 2 or (c < 0xF0 and 3 or 4)))
        taken = taken + 1
      end
      cut = (taken == pend - cap) and (i - 1) or nil
      if cut and cut > #prefix and rl[cut] and rl[cut] > #cr then
        local part = text:sub(#prefix + 1, cut)
        early.committed_text = text:sub(1, cut)
        early.committed_raw = full_raw:sub(1, rl[cut])
        if context.set_property then
          context:set_property("tiger_committed",
            early.committed_raw .. "\t" .. early.committed_text)
        end
        early.trackers = {}
        early.last_seen_raw = ""
        env.engine:commit_text(part)
        context:clear()
        local remaining = full_raw:sub(rl[cut] + 1)
        if remaining ~= "" then context:push_input(remaining) end
      end
      return
    end
  end
end

local function reset_early_state(full, context)
  early.trackers = {}
  early.last_seen_raw = ""
  early.suspended = false
  if full then
    early.committed_text = ""
    early.committed_raw = ""
    -- 已提交链属性随全量重置清空（整句上屏/清空后菜单不再带前缀）。
    if context and context.set_property then
      context:set_property("tiger_committed", "")
    end
  end
end

local function record_and_maybe_commit(env)
  local context = env.engine.context
  local live_raw = context.input
  if type(live_raw) ~= "string" or live_raw == "" then
    reset_early_state(true, context)
    return
  end
  local module = load_engine_module()
  if not module or not module.native_ready() then return end
  if early.suspended then return end

  local full_raw = early.committed_raw .. live_raw
  if #full_raw <= MIN_TOTAL_KEYS then
    early.trackers = {}
    early.last_seen_raw = ""
    return
  end

  local decoded = module.decode_with_early(full_raw)
  if not decoded then return end
  -- 置信源：incomplete tail 存在用 early 行，否则终态行；截断时合并
  -- items/early 可见行（有界视图），且证据须达强档（原版 truncated 时
  -- base_share ≥ 0.999 才计数的对应物）。
  local rows, truncated
  if decoded.uses_incomplete and #(decoded.early or {}) > 0 then
    rows = decoded.early
    truncated = decoded.early_truncated
  else
    rows = decoded.items
    truncated = decoded.truncated
  end
  -- 与非截断分支同规：只统计延伸已提交文本的行，否则已提交前缀的
  -- 兄弟家族（不知首(领) 对 不知道）会分掉前缀质量、证据永远不达标。
  local candidates = {}
  local function collect(list)
    for _, row in ipairs(list or {}) do
      if early.committed_text == ""
          or row.text:sub(1, #early.committed_text) == early.committed_text then
        candidates[#candidates + 1] = row
      end
    end
  end
  if truncated then
    collect(decoded.items)
    collect(decoded.early)
  else
    collect(rows)
  end
  -- 可见首选：提交增量必须与其前缀一致（重排后菜单错位即放弃）。
  local visible_top = nil
  if decoded.items and #decoded.items > 0 then
    visible_top = decoded.items[1].text
  elseif decoded.early and #decoded.early > 0 then
    visible_top = decoded.early[1].text
  end
  -- A capped personalized view cannot prove which hidden paths survived
  -- learning. Verify every truncated generation with an independent search.
  if truncated then
    local base = module.decode_static_with_early
        and module.decode_static_with_early(full_raw) or nil
    if not base then
      early.trackers = {}
      early.last_seen_raw = ""
      return
    end
    candidates = {}
    if base.uses_incomplete and #(base.early or {}) > 0 then
      collect(base.early)
    else
      collect(base.items)
    end
  end

  -- 严格单键续打：全串比上一键恰多 1 键且前缀一致，否则 tracker 清零。
  local extends_evidence = early.last_seen_raw ~= ""
      and #full_raw == #early.last_seen_raw + 1
      and full_raw:sub(1, #early.last_seen_raw) == early.last_seen_raw
  if not extends_evidence then
    early.trackers = {}
  end
  early.last_seen_raw = full_raw

  if #candidates > 0 then
    local qualifying = build_prefix_evidence(candidates, #full_raw, env._tiger_threshold)
    if truncated and qualifying then
      local strong_only = {}
      for _, q in ipairs(qualifying) do
        if q.strong then strong_only[#strong_only + 1] = q end
      end
      qualifying = strong_only
    end
    if qualifying and #qualifying > 0 then
      local next_trackers = {}
      for _, q in ipairs(qualifying) do
        if #q.text > #early.committed_text
            and q.text:sub(1, #early.committed_text) == early.committed_text
            and q.boundary > #early.committed_raw then
          local key = q.text .. "\1" .. q.boundary
          local tracker = early.trackers[key]
          if not tracker then
            tracker = { text = q.text, boundary = q.boundary,
                        evidence = 0, strong = 0, gap = 0 }
          end
          tracker.evidence = math.min(REQUIRED_EVIDENCE, tracker.evidence + 1)
          tracker.strong = q.strong
              and math.min(REQUIRED_STRONG, tracker.strong + 1) or 0
          tracker.gap = 0
          next_trackers[key] = tracker
        end
      end
      early.trackers = next_trackers
      try_commit_mature(env, full_raw, visible_top)
      try_commit_cap(env)
      return
    end
  end
  step_gap_trackers()
  try_commit_mature(env, full_raw, visible_top)
  try_commit_cap(env)
end

function M.processor.init(env)
  local cfg = env.engine.schema.config
  local option = "sentence"
  local ok, value = pcall(cfg.get_string, cfg, "tiger/sentence_option")
  if ok and type(value) == "string" and value:match("^[a-z_][a-z0-9_]*$") then
    option = value
  end
  env._tiger_sentence_option = option
  local early_option = "early_commit"
  local e_ok, e_value = pcall(cfg.get_string, cfg, "tiger/early_commit_option")
  if e_ok and type(e_value) == "string" and e_value:match("^[a-z_][a-z0-9_]*$") then
    early_option = e_value
  end
  env._tiger_early_option = early_option
  -- 前缀质量占比门槛（0.5–1.0，默认 0.99 与虎整句原版一致）。达标前缀
  -- 还须边界封死（0.99999 全票）并连续计票（普通 3 键 / 强档 0.999×2
  -- 键）才提交；调低更激进但误顶上升，见基准报告安全窗说明。
  local threshold = DEFAULT_SHARE
  local t_ok, t_value = pcall(cfg.get_string, cfg, "tiger/early_commit_threshold")
  local number = t_ok and tonumber(t_value) or nil
  if number == nil then
    local i_ok, i_value = pcall(cfg.get_int, cfg, "tiger/early_commit_threshold")
    number = i_ok and tonumber(i_value) or nil
  end
  if number ~= nil and tonumber(string.format("%.2f", number)) == number
      and number > 0.5 and number <= 1.0 then
    threshold = number
  end
  env._tiger_threshold = threshold
  -- 未上屏字数帽（tiger/pending_char_cap，默认 4，0 关闭）：最优候选的
  -- 未提交字数超帽时强制提交超出部分（不要求证据达标——pending 堆高正
  -- 说明证据未封边）。10 万句基准实测：帽=4 净 −4 句、触发 233 次、
  -- 句尾残留 1.49→1.41 字；错上屏句 67→154（错误总量不变、提前可见）。
  local pending_cap = DEFAULT_PENDING_CHAR_CAP
  local p_ok, p_value = pcall(cfg.get_string, cfg, "tiger/pending_char_cap")
  local pnum = p_ok and tonumber(p_value) or nil
  if pnum == nil then
    local pi_ok, pi_value = pcall(cfg.get_int, cfg, "tiger/pending_char_cap")
    pnum = pi_ok and tonumber(pi_value) or nil
  end
  if pnum ~= nil and pnum >= 0 and pnum <= 32 then
    pending_cap = math.floor(pnum)
  end
  env._tiger_pending_cap = pending_cap
end

local BROWSE_KEYS = {
  ["Up"] = true, ["Down"] = true, ["Left"] = true, ["Right"] = true,
  ["Page_Up"] = true, ["Page_Down"] = true, ["Tab"] = true,
  ["Shift+Tab"] = true, ["Home"] = true, ["End"] = true,
}

function M.processor.func(key_event, env)
  local context = env.engine.context
  local raw = context.input
  if type(raw) ~= "string" then raw = "" end
  if raw == "" then reset_early_state(true, context) end
  local repr = key_event:repr()
  if BROWSE_KEYS[repr] and raw ~= "" then
    early.suspended = true
    return kNoop
  end
  if repr == "BackSpace" then
    early.trackers = {}
    early.last_seen_raw = ""
    return kNoop
  end
  -- 只收单个直击小写字母；组合键、大写（ascii 转换）交给后续组件。
  if not repr:match("^[a-z]$") then return kNoop end
  if context.get_option and not context:get_option(env._tiger_sentence_option) then
    return kNoop
  end
  local module = load_engine_module()
  if not module or not module.native_ready() then return kNoop end
  -- 只接管纯字母输入流；快符（;）、反查（`）等前缀由 speller 原路径处理。
  if raw ~= "" and not raw:match("^[a-z]+$") then return kNoop end
  if #raw >= MAX_RAW_LENGTH then return kNoop end
  context:push_input(repr)
  if context.get_option and not context:get_option(env._tiger_early_option) then
    return kAccepted
  end
  record_and_maybe_commit(env)
  return kAccepted
end

-- 单测注入口：替换引擎模块探测结果与提前上屏状态。
M._test = {
  set_engine_module = function(module)
    engine_module = module
    engine_module_attempted = true
  end,
  reset = function()
    engine_module = nil
    engine_module_attempted = false
    reset_early_state(true)
  end,
  state = early,
  build_prefix_evidence = build_prefix_evidence,
  utf8_length = utf8_length,
}

return M
