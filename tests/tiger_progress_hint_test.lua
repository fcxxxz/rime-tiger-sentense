-- tiger_progress_hint 单元测试：空窗进度兜底的门控。
package.path = "./lua/?.lua;" .. package.path

local hint = dofile("lua/tiger_progress_hint.lua")
local t = hint._test

-- librime-lua 环境全局（普通 lua 下打桩）。
Candidate = function(type_, start, finish, text, comment)
    return { type = type_, start = start, _end = finish,
             text = text, comment = comment, preedit = nil }
end

local failures = 0
local function check(name, ok)
    if ok then
        print("ok - " .. name)
    else
        failures = failures + 1
        print("FAIL - " .. name)
    end
end

local function make_env(input)
    local segment = { start = 0, _end = #(input or "") }
    return {
        engine = {
            schema = { config = {} },
            context = {
                input = input or "",
                get_option = function() return true end,
                composition = { back = function() return segment end },
            },
        },
    }
end

local function make_translation(cands)
    local index = 0
    return {
        iter = function()
            return function()
                index = index + 1
                return cands[index]
            end
        end,
    }
end

local function run_filter(input, cands)
    local yielded = {}
    local translation = make_translation(cands)
    yield = function(cand) yielded[#yielded + 1] = cand end
    hint.filter.func(translation, make_env(input))
    yield = nil
    return yielded
end

t.reset()

-- 非空窗：原样透传，不调引擎。
do
    local out = run_filter("shs", { { text = "说" } })
    check("non-empty window passes through", #out == 1 and out[1].text == "说")
end

-- 非字母/超长输入：透传不缓存（此处空表＝透传空）。
do
    local out = run_filter("`ho", { { text = "火" } })
    check("prefixed input passes through", #out == 1 and out[1].text == "火")
end
do
    local out = run_filter("shsa", {})
    check("4-key empty window asks engine (none here → stays empty)", #out == 0)
end

-- 空窗 + 引擎就绪：先联想预判（raw+字母终态），再进度候选。
do
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            if raw == "shs" then
                return {
                    truncated = false, early_truncated = false,
                    early = {
                        { text = "说", segmented = "sh",
                          raw_lengths = { [3] = 2 } },
                        { text = "说", segmented = "sh",
                          raw_lengths = { [3] = 2 } },  -- 重复文本应去重
                        { text = "驶", segmented = "sh",
                          raw_lengths = { [3] = 2 } },
                    },
                    items = {},
                }
            end
            -- 预判探针：仅两个后继字母有终态
            if raw == "shsa" then
                return { truncated = false, early = {},
                    items = { { text = "说话", segmented = "sh sa", confidence = -5 } } }
            end
            if raw == "shsm" then
                return { truncated = false, early = {},
                    items = { { text = "说出", segmented = "sh sm", confidence = -7 } } }
            end
            return { truncated = false, early = {}, items = {} }
        end,
    })
    local out = run_filter("shs", {})
    check("predictions precede progress candidates",
          #out == 4 and out[1].text == "说话" and out[2].text == "说出"
          and out[3].text == "说" and out[4].text == "驶")
    check("preedit stays the real input (never the predicted code)",
          out[1].preedit == "shs" and out[3].preedit == "shs")
    check("prediction comment hints the saved key, progress uses ellipsis",
          out[1].comment == "+a" and out[2].comment == "+m"
          and out[3].comment == "…")
    check("progress span covers only consumed keys (tail stays editable)",
          out[3].start == 0 and out[3]._end == 2)
end

-- 截断的 early 行不补（beam 不完整时宁空勿误）。
do
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function()
            return { truncated = true, early = {
                { text = "说", segmented = "sh" } } }
        end,
    })
    local out = run_filter("shs", {})
    check("truncated early rows suppressed", #out == 0)
end

-- 引擎不可用：空窗不介入（与上游行为一致）。
do
    t.set_engine_module({ native_ready = function() return false end })
    local out = run_filter("shs", {})
    check("offline engine keeps window empty", #out == 0)
end

-- 单字模式（sentence off）：整体让位，直通候选、不注入预判/进度。
do
    t.set_engine_module({ native_ready = function() return true end })
    local segment = { start = 0, _end = 3 }
    local env = {
        engine = {
            schema = { config = {} },
            context = {
                input = "shs",
                get_option = function(_, name)
                    if name == "sentence" then return false end
                    return true
                end,
                composition = { back = function() return segment end },
            },
        },
    }
    hint.filter.init(env)
    local yielded = {}
    local translation = make_translation({ { text = "说" } })
    yield = function(cand) yielded[#yielded + 1] = cand end
    hint.filter.func(translation, env)
    yield = nil
    check("sentence off passes table candidates through",
        #yielded == 1 and yielded[1].text == "说")
    -- 空窗也不注入引擎预判。
    local yielded2 = {}
    local empty = make_translation({})
    yield = function(cand) yielded2[#yielded2 + 1] = cand end
    hint.filter.func(empty, env)
    yield = nil
    check("sentence off keeps empty window empty", #yielded2 == 0)
end

-- 5+ 键空窗（说的是＝shueo，尾 o 未成码）：同样要预判/进度兜底。
do
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            if raw == "shueoe" then
                return { truncated = false, early_truncated = false,
                         items = { { text = "说的是", confidence = 1.0 } },
                         early = {} }
            end
            if raw == "shueo" then
                return { truncated = false, early_truncated = false,
                         items = {},
                         early = { { text = "说的",
                                     raw_lengths = { [6] = 4 } } } }
            end
            return { truncated = false, early_truncated = false,
                     items = {}, early = {} }
        end,
    })
    local out = run_filter("shueo", {})
    local predict, progress
    for _, cand in ipairs(out) do
        if cand.type == "tiger_predict" then predict = cand end
        if cand.type == "tiger_progress" then progress = cand end
    end
    check("5-key empty window gets prediction",
        predict ~= nil and predict.text == "说的是" and predict.comment == "+e")
    check("5-key empty window gets progress",
        progress ~= nil and progress.text == "说的" and progress._end == 4)
end

-- 提前上屏后尾码空窗：拼已提交链解码、裁前缀、平移跨度。
do
    t.set_engine_module({
        native_ready = function() return true end,
        decode_with_early = function(raw)
            if raw == "shueoe" then
                return { truncated = false, early_truncated = false,
                         items = { { text = "说的是", confidence = 1.0 } },
                         early = {} }
            end
            if raw == "shueo" then
                return { truncated = false, early_truncated = false,
                         items = {},
                         early = { { text = "说的是",
                                     raw_lengths = { [9] = 6 } } } }
            end
            return { truncated = false, early_truncated = false,
                     items = {}, early = {} }
        end,
    })
    local segment = { start = 0, _end = 1 }
    local env = make_env("o")
    env.engine.context.set_property = nil
    env.engine.context.get_property = function()
        return "shue\t说的"
    end
    env.engine.context.composition = { back = function() return segment end }
    local yielded = {}
    local translation = make_translation({})
    yield = function(cand) yielded[#yielded + 1] = cand end
    hint.filter.func(translation, env)
    yield = nil
    local predict, progress
    for _, cand in ipairs(yielded) do
        if cand.type == "tiger_predict" then predict = cand end
        if cand.type == "tiger_progress" then progress = cand end
    end
    check("committed chain strips prediction prefix",
        predict ~= nil and predict.text == "是")
    check("committed chain progress shifts span to live codes",
        progress ~= nil and progress.text == "是" and progress._end == 1
        and progress.preedit == "o")
end

t.reset()

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("all checks passed")
