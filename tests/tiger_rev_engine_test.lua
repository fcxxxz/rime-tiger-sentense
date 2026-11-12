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

-- 全拼贪心切音节（数据来自 tiger_rev_syllables，build_rev_dicts.py 学出）
check("nihao → nihk", t.pinyin_to_zrm("nihao") == "nihk")
check("zhongguo → vsgo", t.pinyin_to_zrm("zhongguo") == "vsgo")
check("apostrophe 分隔 ni'hao → nihk", t.pinyin_to_zrm("ni'hao") == "nihk")
check("xian 整音节优先 → xm", t.pinyin_to_zrm("xian") == "xm")
check("lv → lv", t.pinyin_to_zrm("lv") == "lv")
check("er → er", t.pinyin_to_zrm("er") == "er")
check("单音节 ni → ni", t.pinyin_to_zrm("ni") == "ni")
check("切不出的串 → nil", t.pinyin_to_zrm("nix") == nil)
check("空串 → 空流", t.pinyin_to_zrm("") == "")

-- 质量带落位（tiger_reverse_mode 的带：zrm 900–1900 / flypy 1900–2900 /
-- pinyin 2900–3900）
check("zrm quality 在带内", t.quality.zrm >= 900 and t.quality.zrm < 1900)
check("flypy quality 在带内", t.quality.flypy >= 1900 and t.quality.flypy < 2900)
check("pinyin quality 在带内", t.quality.pinyin >= 2900 and t.quality.pinyin < 3900)

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("all checks passed")
