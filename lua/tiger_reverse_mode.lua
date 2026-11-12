-- 虎码方案的嵌入魔虎反查：码式门控与循环切换。
--
-- 三码式共用 reverse_lookup tag，靠 table_translator 的质量带区分
-- （rev_zrm 1000 / rev_flypy 2000 / rev_pinyin 3000）。当前码式由两个
-- 布尔 option 编码：rev_flypy + rev_full：
--   false/false = 自然码双拼（默认）；true/false = 小鹤双拼；
--   /true/ = 全拼。
-- Ctrl+R（processor）按本包可用词典循环：词典缺席的码式自动跳过
-- （探测 build/<dict>.table.bin；2026-11-12 修复：原探测 mohu_*.words
-- 是旧配置残留，装机永不编译致 Ctrl+R 卡死）。gate 只放行当前码式
-- 质量带内的候选，其余码式的候选整段丢弃——切换即时生效，无需重部署。

local kAccepted = 1
local kNoop = 2

local M = { processor = {}, filter = {} }

local MODES = {
  { key = "zrm", flypy = false, full = false, band_lo = 900, band_hi = 1900,
    tip = "〔反查·自然码｜Ctrl+R 切小鹤〕" },
  { key = "flypy", flypy = true, full = false, band_lo = 1900, band_hi = 2900,
    tip = "〔反查·小鹤｜Ctrl+R 切全拼〕" },
  { key = "pinyin", flypy = false, full = true, band_lo = 2900, band_hi = 3900,
    tip = "〔反查·全拼｜Ctrl+R 切双拼〕" },
}

local function current_mode(context)
  if context:get_option("rev_full") then return MODES[3] end
  if context:get_option("rev_flypy") then return MODES[2] end
  return MODES[1]
end

local function data_dirs()
  -- 标准前端：编译产物在 <user>/build/；mira 测试宿主把编译缓存当共享
  -- 目录（user 目录本身无产物）；兼容个别宿主铺在用户目录根部。
  local dirs = {}
  local api = rawget(_G, "rime_api")
  if api then
    if type(api.get_user_data_dir) == "function" then
      local ok, user = pcall(api.get_user_data_dir)
      if ok and type(user) == "string" and user ~= "" then
        dirs[#dirs + 1] = user:gsub("/+$", "") .. "/build"
        dirs[#dirs + 1] = user:gsub("/+$", "")
      end
    end
    if type(api.get_shared_data_dir) == "function" then
      local ok, shared = pcall(api.get_shared_data_dir)
      if ok and type(shared) == "string" and shared ~= "" then
        dirs[#dirs + 1] = shared:gsub("/+$", "")
      end
    end
  end
  return dirs
end

local function file_available(rel_path)
  local dirs = data_dirs()
  if #dirs == 0 then return true end -- 探测不可用时保守放行
  for _, base in ipairs(dirs) do
    local probe = io.open(base .. "/" .. rel_path, "r")
    if probe then
      probe:close()
      return true
    end
  end
  return false
end

local function available_modes()
  -- 2026-11-12 反查走引擎模型后探测 lexicon 数据文件（tiger_rev_engine
  -- 直接喂引擎，无编译产物）；全拼模式复用 zrm lexicon（lua 层切音节）。
  local checks = {
    zrm = "mohu/data/zrm/mohu_zrm.lexicon.txt",
    flypy = "mohu/data/flypy/mohu_flypy.lexicon.txt",
    pinyin = "mohu/data/zrm/mohu_zrm.lexicon.txt",
  }
  local available = {}
  for _, mode in ipairs(MODES) do
    if file_available(checks[mode.key]) then
      available[#available + 1] = mode
    end
  end
  if #available == 0 then return { MODES[1] } end
  return available
end

function M.processor.init(env)
  env._trm_cycle_hotkey = "Control+r"
end

-- 纯函数：当前码式在可用列表中的下一码式（环形；当前缺席则回列表头）。
local function cycle_from(current, modes)
  for index, mode in ipairs(modes) do
    if mode == current and modes[index + 1] then
      return modes[index + 1]
    end
  end
  return modes[1]
end

function M.processor.func(key_event, env)
  if key_event:repr() ~= env._trm_cycle_hotkey then return kNoop end
  local context = env.engine.context
  local next_mode = cycle_from(current_mode(context), available_modes())
  context:set_option("rev_flypy", next_mode.flypy)
  context:set_option("rev_full", next_mode.full)
  return kAccepted
end

-- 纯函数：候选质量是否落在码式质量带内（无质量值时放行）。
local function in_band(mode, quality)
  if type(quality) ~= "number" then return true end
  return quality >= mode.band_lo and quality < mode.band_hi
end

function M.filter.func(input, env)
  local context = env.engine.context
  local raw = type(context.input) == "string" and context.input or ""
  if raw:sub(1, 1) ~= "`" then
    for cand in input:iter() do yield(cand) end
    return
  end
  local mode = current_mode(context)
  -- 动态码式提示：把反查段的 prompt 刷成「当前码式 + Ctrl+R 下一态」，
  -- 每（含 set_option 触发的）翻译刷新一次；prompt 读写失败不影响门控。
  pcall(function()
    local seg = context.composition:back()
    if seg and seg.has_tag and seg:has_tag("reverse_lookup") then
      seg.prompt = mode.tip
    end
  end)
  for cand in input:iter() do
    if in_band(mode, cand.quality) then
      yield(cand)
    end
  end
end

M._test = {
  modes = MODES,
  cycle_from = cycle_from,
  in_band = in_band,
  current_mode = function(flypy, full)
    local context = {
      get_option = function(_, name)
        if name == "rev_flypy" then return flypy end
        if name == "rev_full" then return full end
        return false
      end,
    }
    return current_mode(context)
  end,
}

return M
