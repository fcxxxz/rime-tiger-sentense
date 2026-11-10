local schemas = {
    "mohu_zrm.schema.yaml",
    "mohu_flypy.schema.yaml",
}

local function read(path)
    local file = assert(io.open(path, "r"))
    local text = file:read("*a")
    file:close()
    return text
end

for _, path in ipairs(schemas) do
    local text = read(path)
    assert(text:find("lua_processor@*mohu_candidate_manager*manager_processor", 1, true), path)
    assert(text:find("lua_translator@*mohu_candidate_manager*manager_translator", 1, true), path)
    assert(text:find([[candidate_manager: "^==[hopwlu]?[a-z]*$"]], 1, true), path)
    local alphabet = assert(text:match("alphabet:%s*([^\n]+)"), path)
    assert(alphabet:find("=", 1, true), path .. " alphabet")
end

local shared = read("mohu.yaml")
assert(shared:find("candidate_manager:", 1, true))
assert(shared:find([[prefix: "=="]], 1, true))

local manager = read("lua/mohu_candidate_manager.lua")
assert(not manager:find("空格查看", 1, true))

-- 独立仓 Makefile 用 lua-tests 循环跑全部 tests/*_test.lua，不再逐条
-- 显式调用；这里只断言循环入口与解释器变量存在。
local makefile = read("Makefile")
assert(makefile:find("for t in tests/*_test.lua", 1, true))
assert(makefile:find("MOHU_LUA_BIN", 1, true))

print("candidate manager config: ok")
