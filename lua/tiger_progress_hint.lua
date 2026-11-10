-- 虎码方案空窗进度兜底与联想预判（tiger_progress_hint）
--
-- 形码整句的固有现象：中途前缀不是完整码（或唯一完整码是常用字模式
-- 隐藏的生僻字，如 shs=𡴪、uaw=抺）时候选窗为空——上游虎整句同样
-- 如此。本过滤在「过滤链尽头候选为空」且输入为纯字母时补（任意键长：
-- 词边界 2–4 键与整句中段的未完成尾码都算，说的是＝shu+e+eo 打到
-- shueo 时尾 o 是「是」的半码同样空窗）：
--   ① 联想预判：对 raw+a..z 各做一次增量解码（引擎增量缓存下实测
--      26 键共 3–4ms），取覆盖完整的终态按置信度排序出前几——shs 时
--      预判 说话/说出，选中即整词上屏（相当于替用户预打一键）；
--   ② 进度候选：引擎 early 行（已完整消费前缀+未成码尾巴态），
--      shs 时显示 说…，提示编码正确、继续打即可。
-- 引擎不可用（mira 等宿主）时不介入，行为与上游一致。
-- 挂接：filters 末段（candidate_shadow_filter 之后、uniquifier 之前）。

local M = { filter = {} }

local PREDICT_LIMIT = 3
local PROGRESS_LIMIT = 2

local engine_module
local engine_module_attempted = false

local function load_engine_module()
  if engine_module_attempted then return engine_module end
  engine_module_attempted = true
  local ok, module = pcall(require, "mohu_sentence")
  if ok and type(module) == "table"
      and type(module.native_ready) == "function"
      and type(module.decode_with_early) == "function" then
    engine_module = module
  end
  return engine_module
end

-- 联想预判：26 个后继字母的增量解码，收集恰覆盖 raw+1 键的终态，
-- 按置信度取前 N。返回 { item=终态, extra=预打的那个字母 }——preedit
-- 必须保持真实输入（首候选 preedit 会成为输入行显示串，写成预测完整
-- 码会让用户以为多打了键），预打键放注释提示。
local function predict_completions(module, raw)
  local best = {}
  for byte = string.byte("a"), string.byte("z") do
    local extra = string.char(byte)
    local decoded = module.decode_with_early(raw .. extra)
    if decoded and not decoded.truncated
        and decoded.items and decoded.items[1]
        and type(decoded.items[1].text) == "string"
        and decoded.items[1].text ~= "" then
      best[#best + 1] = { item = decoded.items[1], extra = extra }
    end
    if #best >= 26 then break end
  end
  table.sort(best, function(a, b)
    return a.item.confidence > b.item.confidence
  end)
  local picked = {}
  local seen = {}
  for _, entry in ipairs(best) do
    if not seen[entry.item.text] then
      seen[entry.item.text] = true
      picked[#picked + 1] = entry
      if #picked >= PREDICT_LIMIT then break end
    end
  end
  return picked
end

function M.filter.init(env)
  -- 与 tiger_mode_proc 同源读 tiger/sentence_option：单字模式下本过滤
  -- 整体让位——空窗兜底是整句体验的一部分，单字模式空窗就是空码顶字
  -- （speller 路径），不能把引擎整句预测注入进去（2026-10-27 用户实测
  -- 「开了单字输入还不是单字」的来源）。
  local option = "sentence"
  local cfg = env and env.engine and env.engine.schema and env.engine.schema.config
  if cfg then
    local ok, value = pcall(cfg.get_string, cfg, "tiger/sentence_option")
    if ok and type(value) == "string" and value:match("^[a-z_][a-z0-9_]*$") then
      option = value
    end
  end
  env._tiger_hint_sentence_option = option
end

function M.filter.func(input, env)
  local context = env.engine.context
  -- 单字模式让位：直通上游候选，不注入预判/进度。
  local option = env._tiger_hint_sentence_option or "sentence"
  if context.get_option and not context:get_option(option) then
    for cand in input:iter() do yield(cand) end
    return
  end
  local raw = type(context.input) == "string" and context.input or ""
  -- 任意长度纯字母输入都可能空窗：整句中尾部是未完成码时（说的是＝shu+e+eo
  -- 打到 shueo，尾 o 是「是」的半码），翻译器无终态、表也无候选。原先只
  -- 认 2–4 键（词边界场景），第 5 键起空窗无兜底（2026-10-27 用户实测）。
  local eligible = raw:match("^[a-z]+$") ~= nil

  local buffered = {}
  if eligible then
    for cand in input:iter() do
      buffered[#buffered + 1] = cand
      if #buffered >= 50 then break end
    end
  end
  if #buffered > 0 or not eligible then
    if not eligible then
      for cand in input:iter() do yield(cand) end
    else
      for _, cand in ipairs(buffered) do yield(cand) end
    end
    return
  end

  -- 空窗：联想预判 + 进度候选。
  local module = load_engine_module()
  if not module or not module.native_ready() then return end
  local segment = context.composition and context.composition:back()
  local seg_start = (segment and (segment.start or segment._start)) or 0
  local seg_end = (segment and segment._end) or #raw

  -- 提前上屏后 live raw 只是尾码：拼已提交链解码（与 processor/translator
  -- 同规），预判/进度文本裁掉已提交前缀、边界平移到尾码坐标系。
  local committed_raw, committed_text = "", ""
  if context.get_property then
    local prop = tostring(context:get_property("tiger_committed") or "")
    local cr, ct = prop:match("^([a-z]+)\t(.+)$")
    if cr and ct ~= "" then committed_raw, committed_text = cr, ct end
  end
  local full_raw = committed_raw .. raw
  local prefix_bytes = #committed_text

  for _, entry in ipairs(predict_completions(module, full_raw)) do
    local text = entry.item.text
    if prefix_bytes > 0 then
      if #text <= prefix_bytes or text:sub(1, prefix_bytes) ~= committed_text then
        -- 预判不延续已提交文本时不可信，跳过。
        goto continue_predict
      end
      text = text:sub(prefix_bytes + 1)
    end
    if text ~= "" then
      -- preedit 固定为真实输入；注释提示预打键（选中即省这一键）。
      local cand = Candidate("tiger_predict", seg_start, seg_end,
                             text, "+" .. entry.extra)
      cand.preedit = raw
      yield(cand)
    end
    ::continue_predict::
  end

  local decoded = module.decode_with_early(full_raw)
  if decoded and not decoded.truncated and not decoded.early_truncated then
    local shown = 0
    local seen = {}
    for _, row in ipairs(decoded.early or {}) do
      if type(row.text) == "string" and row.text ~= "" and not seen[row.text] then
        seen[row.text] = true
        local text = row.text
        if prefix_bytes > 0 then
          if #text <= prefix_bytes or text:sub(1, prefix_bytes) ~= committed_text then
            goto continue_progress
          end
          text = text:sub(prefix_bytes + 1)
        end
        -- 跨度只覆盖该文本实际消费的键（行 raw_lengths 的最大边界）：
        -- 拿整段跨度会把未成码尾巴一起吞掉（rpl 选「皮」时 l 消失、
        -- 无法续打）；剩余键留给 composition 继续编辑。
        local consumed = 0
        for _, boundary in pairs(row.raw_lengths or {}) do
          if type(boundary) == "number" and boundary > consumed
              and boundary <= #full_raw then
            consumed = boundary
          end
        end
        if consumed <= 0 then consumed = #full_raw end
        -- 平移到尾码坐标系：已提交部分不占 live 跨度。
        local live_consumed = consumed - #committed_raw
        if live_consumed > 0 then
          local cand = Candidate("tiger_progress", seg_start,
                                 seg_start + live_consumed, text, "…")
          cand.preedit = raw
          yield(cand)
          shown = shown + 1
        end
        if shown >= PROGRESS_LIMIT then break end
      end
      ::continue_progress::
    end
  end
end

-- 单测注入口。
M._test = {
  set_engine_module = function(module)
    engine_module = module
    engine_module_attempted = true
  end,
  reset = function()
    engine_module = nil
    engine_module_attempted = false
  end,
}

return M
