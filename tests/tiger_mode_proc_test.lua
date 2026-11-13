-- tiger_mode_proc 单元测试：整句模式字母接管门控 + 提前上屏规则。
package.path = "./lua/?.lua;" .. package.path

local proc = dofile("lua/tiger_mode_proc.lua")
local t = proc._test

local failures = 0
local function check(name, ok)
    if ok then
        print("ok - " .. name)
    else
        failures = failures + 1
        print("FAIL - " .. name)
    end
end

local kAccepted, kNoop = 1, 2

local function make_key(repr)
    return { repr = function() return repr end }
end

local function make_env(options, input)
    options = options or {}
    local pushed = {}
    local commits = {}
    local context = {}
    context.input = input or ""
    context.get_option = function(_, name) return options[name] end
    context.push_input = function(_, text)
        pushed[#pushed + 1] = text
        context.input = context.input .. text
    end
    context.clear = function() context.input = "" end
    local env = {
        _tiger_sentence_option = "sentence",
        _tiger_early_option = "early_commit",
        engine = {
            schema = { config = {} },
            context = context,
            commit_text = function(_, text) commits[#commits + 1] = text end,
        },
    }
    return env, pushed, commits, context
end

local fake_ready = { native_ready = function() return true end }
local fake_offline = { native_ready = function() return false end }

proc._test.reset()

-- 引擎未就绪：整体让位（mira 宿主/缺 dylib 的降级路径）。
do
    local env, pushed = make_env({ sentence = true }, "")
    proc._test.set_engine_module(fake_offline)
    check("offline engine passes letters through",
          proc.processor.func(make_key("a"), env) == kNoop and #pushed == 0)
end

-- 引擎就绪 + 整句开：字母被接管并追加输入。
do
    local env, pushed = make_env({ sentence = true }, "ue")
    proc._test.set_engine_module(fake_ready)
    check("ready engine accepts and appends letter",
          proc.processor.func(make_key("a"), env) == kAccepted
          and pushed[1] == "a" and env.engine.context.input == "uea")
end

-- 整句关：字母交回 speller（单字顶屏模式）。
do
    local env, pushed = make_env({ sentence = false }, "ue")
    check("sentence off passes letters through",
          proc.processor.func(make_key("a"), env) == kNoop and #pushed == 0)
end

-- 前缀输入（反查 `、快符 ;）不接管。
do
    local env, pushed = make_env({ sentence = true }, "`hu")
    check("backtick prefix not taken over",
          proc.processor.func(make_key("o"), env) == kNoop and #pushed == 0)
end
do
    local env, pushed = make_env({ sentence = true }, ";")
    check("semicolon prefix not taken over",
          proc.processor.func(make_key("w"), env) == kNoop and #pushed == 0)
end

-- 非直击小写字母（组合键、大写、编辑键）不接管。
for _, repr in ipairs({ "space", "Shift+a", "Control+a", "BackSpace", "A" }) do
    local env, pushed = make_env({ sentence = true }, "")
    check(("non-plain key %s passes through"):format(repr),
          proc.processor.func(make_key(repr), env) == kNoop and #pushed == 0)
end

-- 128 键上限：不再追加。
do
    local env, pushed = make_env({ sentence = true }, string.rep("a", 128))
    check("raw length cap stops appending",
          proc.processor.func(make_key("b"), env) == kNoop and #pushed == 0)
end

-- utf8_length
check("utf8_length ascii", t.utf8_length("abc") == 3)
check("utf8_length cjk", t.utf8_length("虎码整句") == 4)

-- build_prefix_evidence：前缀质量占比 + 边界封死双闸。
do
    local rows = {
        { text = "整句输入", confidence = math.log(0.90), pathmap = "6:4,12:8" },
        { text = "整句输出", confidence = math.log(0.09), pathmap = "6:4,12:8" },
        { text = "整句输入法", confidence = math.log(0.005), pathmap = "6:4,12:8,15:10" },
    }
    -- "整句" 前缀质量 = 0.995 ≥0.99 且边界全票；"整句输入" = 0.905 不过。
    local q = t.build_prefix_evidence(rows, 10, 0.99)
    check("qualifying prefix needs share gate",
          q ~= nil and #q >= 1 and q[1].text == "整句" and q[1].boundary == 4)
end
do
    local rows = {
        { text = "整句输入", confidence = math.log(0.90), pathmap = "6:4,12:8" },
        { text = "别的文本", confidence = math.log(0.10), pathmap = "6:4,12:8" },
    }
    -- 所有前缀质量 0.9 < 0.99：无达标前缀。
    local q = t.build_prefix_evidence(rows, 8, 0.99)
    check("below share threshold yields none", q == nil or #q == 0)
end
do
    -- 分歧行破坏边界封死：两行同前缀「整句」但切点码长 4/5 不一致，
    -- 该切点不达标；分叉之后的前缀（整句输入）仍可独立达标。
    local rows = {
        { text = "整句输入", confidence = math.log(0.99), pathmap = "6:4,12:8" },
        { text = "整句体现", confidence = math.log(0.01), pathmap = "6:5,12:8" },
    }
    local q = t.build_prefix_evidence(rows, 8, 0.99)
    local disputed = false
    for _, e in ipairs(q or {}) do
        if e.boundary == 4 then disputed = true end
    end
    check("boundary disagreement blocks the disputed cut",
          not disputed and q ~= nil and #q >= 1)
end
do
    check("empty rows give no evidence",
          t.build_prefix_evidence({}, 8, 0.99) == nil)
end

-- 优化对照：冻结旧算法，精确比较字段（含浮点数），不使用误差容限。
local function reference_prefix_evidence(rows, raw_length, threshold)
    local function logsumexp(values)
        local peak = -math.huge
        for _, value in ipairs(values) do
            if value > peak then peak = value end
        end
        if peak == -math.huge then return peak end
        local sum = 0.0
        for _, value in ipairs(values) do sum = sum + math.exp(value - peak) end
        return peak + math.log(sum)
    end
    local function lengths_for(row)
        if row.raw_lengths then return row.raw_lengths end
        local lengths = {}
        for bytes, boundary in (row.pathmap or ""):gmatch("(%d+):(%d+)") do
            lengths[tonumber(bytes)] = tonumber(boundary)
        end
        return lengths
    end
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
    threshold = threshold or 0.99
    if not rows or #rows == 0 then return nil end
    local masses = {}
    for i, row in ipairs(rows) do masses[i] = row.confidence end
    local total = logsumexp(masses)
    if total == -math.huge then return nil end
    local prefix_masses, cut_masses = {}, {}
    for _, row in ipairs(rows) do
        local counted = {}
        for bytes, boundary in pairs(lengths_for(row)) do
            if type(bytes) == "number" and type(boundary) == "number"
                    and bytes > 0 and boundary > 0 and boundary <= raw_length then
                local prefix = prefix_by_bytes(row.text, bytes)
                if prefix ~= "" and not counted[prefix] then
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
    local qualifying, prefix_learning = {}, {}
    for _, row in ipairs(rows) do
        if row.learning_affected then
            for bytes in pairs(lengths_for(row)) do
                if type(bytes) == "number" and bytes > 0 then
                    local prefix = prefix_by_bytes(row.text, bytes)
                    if prefix ~= "" then prefix_learning[prefix] = true end
                end
            end
        end
    end
    for key, clist in pairs(cut_masses) do
        local prefix, digits = key:match("^(.-)\1(%d+)$")
        local pmass = logsumexp(prefix_masses[prefix])
        local share = math.exp(pmass - total)
        if share >= threshold then
            local boundary_share = math.exp(logsumexp(clist) - pmass)
            if boundary_share >= 0.99999 then
                qualifying[#qualifying + 1] = {
                    text = prefix, boundary = tonumber(digits), share = share,
                    strong = share >= 0.999 and not prefix_learning[prefix],
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

local function same_evidence(rows, raw_length, threshold)
    local expected = reference_prefix_evidence(rows, raw_length, threshold)
    local actual = t.build_prefix_evidence(rows, raw_length, threshold)
    if expected == nil or actual == nil then return expected == actual end
    if #expected ~= #actual then return false end
    for i, e in ipairs(expected) do
        for key, value in pairs(e) do
            if actual[i][key] ~= value then return false end
        end
        for key, value in pairs(actual[i]) do
            if e[key] ~= value then return false end
        end
    end
    return true
end

do
    local exact = same_evidence(nil, 8) and same_evidence({}, 8)
        and same_evidence({ { text = "虎", confidence = -math.huge,
                             raw_lengths = { [3] = 2 } } }, 8)
    -- 质量门槛、强档门槛、边界封死门槛的两侧及恰好相等。
    for _, gate in ipairs({ 0.99, 0.999, 0.99999 }) do
        for _, delta in ipairs({ -1e-14, 0, 1e-14 }) do
            local p = gate + delta
            for _, boundary in ipairs({ 4, 5 }) do
                local rows = {
                    { text = "虎码输入", confidence = math.log(p),
                      raw_lengths = { [6] = 4, [12] = 8 } },
                    { text = boundary == 4 and "别的文本" or "虎码输出",
                      confidence = math.log(1 - p),
                      raw_lengths = { [6] = boundary, [12] = 8 } },
                }
                exact = exact and same_evidence(rows, 8, gate)
            end
        end
    end
    -- 每字节切点、同前缀不同码长、超长/非法切点和学习污染。
    local mixed = {
        { text = "aé虎𠀀码", confidence = 0,
          raw_lengths = { [1] = 1, [2] = 2, [3] = 3, [4] = 4,
                          [6] = 5, [10] = 6, [13] = 7, [99] = 8 } },
        { text = "aé虎𠀀码", confidence = -20, learning_affected = true,
          raw_lengths = { [1] = 99, [3] = false, [6] = "bad", [13] = -1,
                          [0] = 1, [-1] = 2, bad = 2, [99] = 8 } },
    }
    exact = exact and same_evidence(mixed, 8, 0)
    check("optimized evidence matches old function at gates and UTF8 cuts", exact)
end

do
    -- 独立确定性随机源，避免改变后续测试的 math.random 状态。
    local seed = 20261026
    local function random(n)
        seed = (seed * 48271) % 2147483647
        return seed % n + 1
    end
    local chars = { "虎", "码", "输", "入", "a", "é", "𠀀" }
    local thresholds = { 0, 0.5, 0.99, 0.999, 0.99999, 1 }
    local exact = true
    for fixture = 1, 2000 do
        local rows, raw_length = {}, random(24)
        local shared = chars[random(#chars)] .. chars[random(#chars)]
        for i = 1, random(30) do
            local text = random(3) == 1 and "" or shared
            for _ = 1, random(10) do text = text .. chars[random(#chars)] end
            local lengths, pathmap = {}, {}
            for _ = 1, random(20) do
                local bytes, boundary = random(#text + 5) - 1, random(28) - 1
                lengths[bytes] = boundary
                pathmap[#pathmap + 1] = bytes .. ":" .. boundary
            end
            local row = { text = text, confidence = -random(1000) / 17,
                          learning_affected = random(5) == 1 }
            if random(2) == 1 then row.raw_lengths = lengths
            else row.pathmap = table.concat(pathmap, ",") end
            rows[i] = row
        end
        if not same_evidence(rows, raw_length, thresholds[random(#thresholds)]) then
            exact = false
            print("differing random evidence fixture " .. fixture)
            break
        end
    end
    check("optimized evidence matches old function on 2000 random fixtures", exact)
end

-- 端到端回归：模型未收敛期的分叉读法（维及）不污染后续收敛读法
-- （退化）——tracker 按前缀独立计票，旧「公共前缀」实现会被判死整句。
do
    proc._test.reset()
    local phase = 0
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            phase = phase + 1
            local early_rows
            if phase <= 2 then
                -- 未收敛期：维(边界分歜)+维及(质量 0.98<0.99)，全切点不达标。
                early_rows = {
                    { text = "维及要", confidence = math.log(0.98),
                      pathmap = "3:1,6:3,9:5" },
                    { text = "维系", confidence = math.log(0.02),
                      pathmap = "3:2,6:4" },
                }
            else
                early_rows = {
                    { text = "退化出", confidence = math.log(0.999),
                      pathmap = "6:4,9:6" },
                }
            end
            return { truncated = false, uses_incomplete = true,
                     early_truncated = false, items = {}, early = early_rows }
        end,
    })
    local env, _, commits, context = make_env(
        { sentence = true, early_commit = true }, "")
    for _, key in ipairs({ "i", "u", "c", "j", "v", "b", "s", "m" }) do
        proc.processor.func(make_key(key), env)
    end
    -- k5/k6 解码为「维及」族（share 0.98 不达标），k7/k8 稳定「退化」族：
    -- 强档 ×2 于 k8 提交「退化出」（边界最深 6），余码 sm 续打。
    check("divergent early readings do not poison later convergence",
          commits[1] == "退化出" and context.input == "sm")
end

-- 端到端：模拟连续打字（终态置信源）。>4 键门槛下证据从第 5 键起计，
-- 单行独占质量 → 强档，连续 2 键（第 6 键）即提交「整句」（边界 4），
-- 余码回填；第 7 键继续追加。
do
    proc._test.reset()
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            return {
                truncated = false, early_truncated = false, uses_incomplete = false,
                items = {
                    { text = "整句输入", confidence = math.log(0.999),
                      pathmap = "6:4,12:8" },
                },
                early = {},
            }
        end,
    })
    local env, pushed, commits, context = make_env(
        { sentence = true, early_commit = true }, "")
    for _, key in ipairs({ "x", "h", "f", "g", "j", "y", "j" }) do
        proc.processor.func(make_key(key), env)
    end
    check("strong evidence commits on second consecutive key",
          commits[1] == "整句")
    -- 全串 7 键、边界 4：第 6 键提交后余码 jy 回填，第 7 键 j 追加。
    check("remaining raw pushed back", context.input == "jyj")
end

-- 提前上屏关：只接管字母，不提交。
do
    proc._test.reset()
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            return {
                truncated = false, uses_incomplete = false,
                items = {
                    { text = "整句输入", confidence = math.log(0.999),
                      pathmap = "6:4,12:8" } },
                early = {},
            }
        end,
    })
    local env, _, commits = make_env({ sentence = true, early_commit = false }, "")
    for _, key in ipairs({ "x", "h", "f", "g", "j", "y", "j" }) do
        proc.processor.func(make_key(key), env)
    end
    check("early_commit off never commits", #commits == 0)
end

-- 截断 + 可见共识：退用可见行前缀质量提案，长输入仍可触发提交。
do
    proc._test.reset()
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            return {
                truncated = true, early_truncated = true,
                visible_consensus = true, consensus_complete = true,
                consensus_text_bytes = 0, consensus_raw_length = 0,
                items = {
                    { text = "不知首领", confidence = math.log(0.90),
                      pathmap = "3:2,6:4,9:6,12:8" },
                },
                early = {},
            }
        end,
    })
    local env, _, commits = make_env({ sentence = true, early_commit = true }, "")
    -- c=不 b=不? 用 4 键一族模拟：>4 键后每键提案「不知」（质量 0.90<0.995
    -- 拿不到——构造可见质量 0.999 的「不知」行确保过阈值）。
    local stronger = {
        native_ready = function() return true end,
        decode_with_early = function(raw)
            return {
                truncated = true, early_truncated = true,
                visible_consensus = true, consensus_complete = true,
                consensus_text_bytes = 0, consensus_raw_length = 0,
                items = {
                    { text = "不知去向", confidence = math.log(0.999),
                      pathmap = "3:2,6:4,9:6,12:8" },
                },
                early = {},
            }
        end,
    }
    stronger.decode_static_with_early = stronger.decode_with_early
    t.set_engine_module(stronger)
    for _, key in ipairs({ "c", "b", "o", "d", "h", "o", "i" }) do
        proc.processor.func(make_key(key), env)
    end
    check("truncated with visible consensus still commits",
          commits[1] == "不知")
    check("tail keeps unconsumed keys", env.engine.context.input == "hoi")
end

for _, scenario in ipairs({ "supported", "ambiguous", "conflict", "legacy" }) do
    t.reset()
    local calls = 0
    local module = {
        native_ready = function() return true end,
        decode_with_early = function()
            return { truncated = true, items = {
                { text = "整句输入", confidence = 0, learning_affected = true,
                  pathmap = "6:4,12:8" },
            }, early = {} }
        end,
    }
    if scenario ~= "legacy" then
        module.decode_static_with_early = function()
            calls = calls + 1
            local rows = {
                { text = scenario == "conflict" and "别的输入" or "整句输入",
                  confidence = 0, pathmap = "6:4,12:8" },
            }
            if scenario == "ambiguous" then
                rows[2] = { text = "别的输入", confidence = 0, pathmap = "6:4,12:8" }
            end
            return { truncated = false, items = rows, early = {} }
        end
    end
    t.set_engine_module(module)
    local env, _, commits = make_env({ sentence = true, early_commit = true }, "")
    for key in ("abcdefgh"):gmatch(".") do
        proc.processor.func(make_key(key), env)
    end
    if scenario == "supported" then
        check("independent static evidence restores learned truncated commits",
              commits[1] == "整句" and calls > 0)
    else
        check("static verification rejects " .. scenario, #commits == 0)
    end
end

-- 强化版1回归（2026-11-13 装机实录）：kukflfks 打「过汧县」，第 5 键
-- 起 过汧（ku kfl）被引擎「孤立生僻字」过滤整行移出——旧行为下第 6 键
-- 终态束真空、过滑 share=1.0 强档×2 误顶上屏。修复后：隐藏行回归置信
-- 质量，过滑 家族第 6 键 share 0.97<0.99 被 qualifying 丢弃，强档连击
-- 无法累积；公共前缀 过 share 恒 1.0 在第 6 键安全提交，终态 过汧县
-- 不再被顶掉。只入质量、禁强档变体已证伪（100k W 156→3881）。
-- 数据为装机参数（γ=6、segment_policy(3,1)、text_lexicon 6.5）实测
-- payload 各键快照。
do
    proc._test.reset()
    local views = {
        ["kuk"] = {
            uses_incomplete = true, items = {},
            early = { { text = "过", confidence = -11.8529608,
                        pathmap = "0:0,3:2" } },
        },
        ["kukf"] = {
            uses_incomplete = false, early = {},
            items = { { text = "过滑", confidence = -17.3434894,
                        pathmap = "0:0,3:2,6:4" } },
        },
        ["kukfl"] = {
            uses_incomplete = true, items = {},
            early = { { text = "过滑", confidence = -17.3434894,
                        pathmap = "0:0,3:2,6:4" } },
            hidden_items = { { text = "过汧", confidence = -28.4986929,
                               pathmap = "0:0,3:2,6:5" } },
            hidden_early = { { text = "过汧", confidence = -28.4986929,
                               pathmap = "0:0,3:2,6:5" } },
        },
        ["kukflf"] = {
            uses_incomplete = true,
            items = { { text = "过滑方", confidence = -24.9797097,
                        pathmap = "0:0,3:2,6:4,9:6" } },
            early = { { text = "过滑方", confidence = -24.9797097,
                        pathmap = "0:0,3:2,6:4,9:6" } },
            hidden_early = { { text = "过汧", confidence = -28.4986929,
                               pathmap = "0:0,3:2,6:5" } },
        },
        ["kukflfk"] = {
            uses_incomplete = true,
            items = { { text = "过滑蓐", confidence = -32.6841778,
                        pathmap = "0:0,3:2,6:4,9:7" },
                      { text = "过汧求", confidence = -32.7169518,
                        pathmap = "0:0,3:2,6:5,9:7" } },
            early = { { text = "过滑方", confidence = -24.9797097,
                        pathmap = "0:0,3:2,6:4,9:6" },
                      { text = "过滑蓐", confidence = -32.6841778,
                        pathmap = "0:0,3:2,6:4,9:7" },
                      { text = "过汧求", confidence = -32.7169518,
                        pathmap = "0:0,3:2,6:5,9:7" } },
        },
        ["kukflfks"] = {
            uses_incomplete = false,
            items = { { text = "过汧县", confidence = -25.3475394,
                        pathmap = "0:0,3:2,6:5,9:8" },
                      { text = "过滑方水", confidence = -30.8771858,
                        pathmap = "0:0,3:2,6:4,9:6,12:8" } },
            early = { { text = "过汧县", confidence = -25.3475394,
                        pathmap = "0:0,3:2,6:5,9:8" },
                      { text = "过滑方水", confidence = -30.8771858,
                        pathmap = "0:0,3:2,6:4,9:6,12:8" } },
        },
    }
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            return views[raw]
        end,
    })
    local env, _, commits, context = make_env(
        { sentence = true, early_commit = true }, "")
    -- 第 1~6 键：过滑 不得上屏（旧代码在第 6 键误顶）；公共前缀 过 在
    -- 第 6 键安全提交（share 恒 1.0，强档不受隐藏行稀释影响）。
    for _, key in ipairs({ "k", "u", "k", "f", "l", "f" }) do
        proc.processor.func(make_key(key), env)
    end
    check("hidden rare row breaks the vacuum share (no 过滑 commit)",
          #commits == 1 and commits[1] == "过" and context.input == "kflf")
    -- 第 7/8 键：过汧县 家族份额被 过滑方 挤出 qualifying，无更多提交。
    proc.processor.func(make_key("k"), env)
    proc.processor.func(make_key("s"), env)
    check("terminal state keeps 过汧县 family (no further commit)",
          #commits == 1 and commits[1] == "过" and context.input == "kflfks")
end

proc._test.reset()

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("all checks passed")
