-- tiger_rev_engine 单元测试：全拼贪心切分 → zrm 码流、质量带落位。
-- 引擎直驱部分（decode_static）由 /tmp 探针或实机覆盖，不在 lua 单测内。
package.path = "./lua/?.lua;./tiger_sentence_native/?.lua;" .. package.path

local m = dofile("lua/tiger_rev_engine.lua")
local t = m._test

local failures = 0
local function check(name, ok)
    if ok then
        print("ok - " .. name)
    else
        failures = failures + 1
        print("FAIL - " .. name)
    end
end

-- 全拼切音节（数据来自 tiger_rev_syllables，build_rev_dicts.py 学出）。
-- 贪心单切分在连续全拼上系统性出错（jidangeng → ji+dang+eng），全部
-- 合法切分并行喂引擎消歧——断言用流成员式。
local function streams_of(q)
    local list = t.pinyin_streams(q)
    if not list then return {} end
    local set = {}
    for _, s in ipairs(list) do set[s] = true end
    return set
end
check("nihao 含 ni+hao", streams_of("nihao")["nihk"] == true)
check("zhongguo 含 zhong+guo", streams_of("zhongguo")["vsgo"] == true)
check("apostrophe 分隔 ni'hao 含 nihk", streams_of("ni'hao")["nihk"] == true)
check("xian 含整音节切分 xm", streams_of("xian")["xm"] == true)
check("lv → lv", t.pinyin_to_zrm("lv") == "lv")
check("er → er", t.pinyin_to_zrm("er") == "er")
check("单音节 ni → ni", t.pinyin_to_zrm("ni") == "ni")
check("切不出的串 → nil", t.pinyin_to_zrm("nix") == nil)
check("空串 → 空流", t.pinyin_to_zrm("") == "")

local jd = streams_of("jidangeng")
check("jidangeng 含正确切分 ji+dan+geng", jd["jidjgg"] == true)
check("jidangeng 含贪心切分 ji+dang+eng（引擎自选）", jd["jidheg"] == true)
check("xianhua 两切分 xian+hua / xi+an+hua", streams_of("xianhua")["xmhw"] == true)
check("切分流上限 8 内", #t.pinyin_streams("jidangeng") <= 8)

-- 质量带落位（tiger_reverse_mode 的带：zrm 900–1900 / flypy 1900–2900 /
-- pinyin 2900–3900）
check("zrm quality 在带内", t.quality.zrm >= 900 and t.quality.zrm < 1900)
check("flypy quality 在带内", t.quality.flypy >= 1900 and t.quality.flypy < 2900)
check("pinyin quality 在带内", t.quality.pinyin >= 2900 and t.quality.pinyin < 3900)

-- 集成段：mock librime-lua 全局（Candidate/yield/Segment 形状）驱动
-- translator.func 全链——覆盖 tags 表判定、option 判型、decode→yield。
-- 引擎件（dylib/模型/lexicon）缺席时整段跳过（CI 无模型）。
local home = os.getenv("HOME") or ""
local model = home .. "/Library/Rime/mohu/model/mohu-sentence-ngram-v5.bin"
local model_probe = io.open(model, "r")
if model_probe then
    model_probe:close()
    -- mock rime_api：mohu_runtime 经 get_user_data_dir 解析引擎/词表路径，
    -- 集成段指向实机用户目录（模型/dylib/lexicon 都在那里）。
    rawset(_G, "rime_api", {
        get_user_data_dir = function() return home .. "/Library/Rime" end,
    })
    local yielded = {}
    Candidate = function(_, _, _, text, comment)  -- 全局 mock
        return { text = text, comment = comment, quality = nil }
    end
    yield = function(c) yielded[#yielded + 1] = c end

    local function run_case(input, options)
        for i = #yielded, 1, -1 do yielded[i] = nil end
        local ctx = {
            input = input,
            get_option = function(_, name) return options[name] == true end,
        }
        local seg = { tags = { reverse_lookup = true }, start = 1, _end = 5 }
        m.translator.func(nil, seg, { engine = { context = ctx } })
        return yielded
    end

    local out = run_case("`nihk", { rev_full = false, rev_flypy = false })
    check("zrm `nihk 出候选（tags 判定+decode+yield 全链）", #out > 0)
    check("zrm `nihk 首选 你好", out[1] and out[1].text == "你好")
    check("候选 quality 落 zrm 带", out[1] and out[1].quality == t.quality.zrm)
    check("注释带码式名（自然码）", out[1] and out[1].comment
          and out[1].comment:find("自然码", 1, true) ~= nil)

    out = run_case("`nihao", { rev_full = true, rev_flypy = false })
    check("pinyin `nihao 出候选（贪心切分→zrm 引擎）", #out > 0)
    check("pinyin `nihao 首选 你好", out[1] and out[1].text == "你好")

    out = run_case("`nihc", { rev_full = false, rev_flypy = true })
    check("flypy `nihc 出候选", #out > 0)

    out = run_case("`jidangeng", { rev_full = true, rev_flypy = false })
    check("pinyin `jidangeng 出候选（多切分合并）", #out > 0)
    local found = false
    for _, c in ipairs(out) do
      if c.text == "鸡蛋羹" then found = true break end
    end
    check("pinyin `jidangeng 含 鸡蛋羹", found)

    out = run_case("nihk", { rev_full = false, rev_flypy = false })
    check("非 ` 前缀不响应", #out == 0)

    -- 单音节走 lexicon 枚举（不依赖 dylib，纯文本二分）；
    -- reading_freq 序与旧 mohu_pinyin 全拼反查一致（感 干 敢 赶 甘…）
    out = run_case("`gj", { rev_full = false, rev_flypy = false })
    check("zrm `gj 单音节枚举 >10 字（全字表）", #out > 10)
    check("zrm `gj 首选 感（readfreq 序）", out[1] and out[1].text == "感")
    check("zrm `gj 次选 干", out[2] and out[2].text == "干")
    out = run_case("`gan", { rev_full = true, rev_flypy = false })
    check("pinyin `gan 切 gj 枚举与双拼同表",
          #out > 10 and out[1] and out[1].text == "感")
    out = run_case("`ni", { rev_full = true, rev_flypy = false })
    check("pinyin `ni 首选 你（reading_freq 序）", out[1] and out[1].text == "你")

    for i = #yielded, 1, -1 do yielded[i] = nil end
    local seg_plain = { tags = { abc = true }, start = 0, _end = 4 }
    m.translator.func(nil, seg_plain,
                      { engine = { context = { input = "`nihk",
                                               get_option = function() return false end } } })
    check("非反查段不响应", #yielded == 0)

    -- 空反查码：码式提示候选（切换后/刚进反查的即时反馈通道）
    out = run_case("`", { rev_full = true, rev_flypy = false })
    check("空码 yield 码式提示候选", #out == 1 and out[1].text:find("全拼", 1, true) ~= nil)
    out = run_case("`", { rev_full = false, rev_flypy = false })
    check("空码提示随码式变（自然码）", #out == 1 and out[1].text:find("自然码", 1, true) ~= nil)
    out = run_case("`", { rev_full = false, rev_flypy = true })
    check("空码提示随码式变（小鹤）", #out == 1 and out[1].text:find("小鹤", 1, true) ~= nil)
else
    print("skip - 引擎集成段（模型不在 " .. home .. "/Library/Rime，CI 环境）")
end

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("all checks passed")
