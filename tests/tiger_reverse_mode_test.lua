-- tiger_reverse_mode 单元测试：反查码式映射、质量带门控与循环次序。
package.path = "./lua/?.lua;" .. package.path

local m = dofile("lua/tiger_reverse_mode.lua")
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

-- option 组合 → 码式映射
check("zrm by default", t.current_mode(false, false) == t.modes[1])
check("flypy via rev_flypy", t.current_mode(true, false) == t.modes[2])
check("pinyin via rev_full", t.current_mode(false, true) == t.modes[3])
check("full wins over flypy", t.current_mode(true, true) == t.modes[3])

-- 质量带门控（band: zrm 900–1900 / flypy 1900–2900 / pinyin 2900–3900）
check("zrm band accepts zrm quality", t.in_band(t.modes[1], 1000))
check("zrm band rejects pinyin quality", not t.in_band(t.modes[1], 3000))
check("pinyin band accepts pinyin quality", t.in_band(t.modes[3], 3000))
check("pinyin band rejects zrm quality", not t.in_band(t.modes[3], 1000))
check("missing quality passes through", t.in_band(t.modes[1], nil))

-- 循环次序：全列表环形；缺席码式跳过；当前不在列表回到列表头
check("full cycle zrm->flypy",
      t.cycle_from(t.modes[1], t.modes) == t.modes[2])
check("full cycle flypy->pinyin",
      t.cycle_from(t.modes[2], t.modes) == t.modes[3])
check("full cycle wraps to zrm",
      t.cycle_from(t.modes[3], t.modes) == t.modes[1])
check("zrm-only package keeps zrm (no-op cycle)",
      t.cycle_from(t.modes[1], { t.modes[1] }) == t.modes[1])
check("trimmed package skips missing flypy",
      t.cycle_from(t.modes[1], { t.modes[1], t.modes[3] }) == t.modes[3])
check("pinyin-only wraps to itself",
      t.cycle_from(t.modes[3], { t.modes[3] }) == t.modes[3])
check("stale mode falls back to head",
      t.cycle_from(t.modes[2], { t.modes[1], t.modes[3] }) == t.modes[1])

if failures > 0 then
    print(("FAILED %d checks"):format(failures))
    os.exit(1)
end
print("all checks passed")
