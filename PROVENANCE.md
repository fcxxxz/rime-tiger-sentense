# PROVENANCE（资产来源清单）

本仓（`整句/`）于 2026-11-10 从魔虎仓 `/Users/fuchuxuan/输入法/rime-tiger` 一次性迁出建立。
魔虎仓自此对本仓只读——所有演进在本仓进行。

- 来源仓快照：HEAD `56fb959d51f62df5cbf94ed35135bc43522e2a14`，工作树另有 38 个未提交变更
  （基线存档：`git -C <魔虎仓> status --porcelain`，与 `/tmp/mohu-baseliine-status.txt` 一致）。

## 取工作树版（含未提交的整句改进：tracker + 静态复核 + TSC1 紧凑 ABI + 缓存分离）

- `tiger.schema.yaml`、`tiger.dict.yaml`
- `lua/tiger_mode_proc.lua`、`lua/tiger_progress_hint.lua`
- `tiger_sentence_native/`（整目录：tigerengine.cc/.h、tigerengine_lua.cc、
  libtigerengine.dylib 351,696B、mohu_tiger_sentence.lua、lexicon、模型 bin+zip、
  lua-5.4.6、build.sh、eval）
- `tests/tiger_mode_proc_test.lua`、`tests/tiger_progress_hint_test.lua`、
  `tests/tiger_static_compact_test.lua`、`tests/tiger_early_learning_native_test.lua`、
  `tests/tigerengine_safety_test.cc`、`tests/tigerengine_lua_safety_test.cc`

这批未提交改动在魔虎仓已经三轮报告验证（CPU 3.661→1.639 ms/键、行为零差异、
误提前上屏 76→73 句）：`bench/perf-final/`、`bench/rerun/`、`bench/search-opt/`。

## 取 HEAD 版（避开魔虎仓另一条无关的半成品「全拼反查重构」工作树改动）

- `mohu_zrm.schema.yaml`、`mohu_flypy.schema.yaml`（仅为反查 prism 编译所需）
- `mohu_pinyin.dict.yaml`（工作树中已被删除）

## 与 HEAD 相同（当时工作树干净，直接整目录拷贝）

- `lua/`（魔虎 lua 框架整目录）、`opencc/`
- `tiger.extended.dict.yaml`、`tiger.user.dict.yaml`
- `mohu.yaml`、`mohu_defs.yaml`、`symbols.yaml`、`default.yaml`、`key_bindings.yaml`
- `mohu_pinyin.schema.yaml`、`mohu_charset.dict.yaml`、`mohu_charset.schema.yaml`
- `mohu_zrm.words.dict.yaml`、`mohu_flypy.words.dict.yaml`（各 83MB，反查词库，
  gitignore 仅磁盘）
- `tests/` 其余 `*_test.lua`、`*.test.yaml`、`fixtures/`、`tigerengine_*_test.cc`
  全套引擎测试

## 大体积数据（gitignore，仅磁盘）

- `corpus/fenci/`（1.5GB，V5 训练语料池分词产物，源自
  `research/lm_sentence_compare/corpus/fenci/`）
- `tiger_sentence_native/mohu-sentence-ngram-v5.bin`（389,671,262B，TCSKNM04）
  及 `.zip` 备份

## 有意不带走的

- `Makefile`（重写为精简版）、`README.md`（新写）
- `tools/`、`recipes/`、`research/`（魔虎码表与打包机器；本仓不重生成码表）
- `mohu_zrm.schema.yaml`/`mohu_flypy.schema.yaml` 的工作树版（反查半成品）
- `tests/` 中依赖 tools/ 的 python 构建测试与 `test_mohu_tiger_sentence_native.py`
  （断言对象是魔虎双拼主方案，非本仓虎码整句方案）

## 基准资产

- `bench/100k/` ← `docs/reports/2026-10-26-tiger-100k-comparison/`（十万句对照全套：
  driver.lua/prepare.py/aggregate.py/report.py + manifest + 语料 + 错误清单）
- `bench/error-replay/` ← `docs/reports/2026-10-27-error-replay/`
- `bench/perf-final/`、`bench/rerun/`、`bench/search-opt/` ← 三轮优化验证报告
- `bench/build_bench_corpus.py` ← `tools/build_bench_corpus.py`（语料路径已改为本仓
  `corpus/fenci/`）
- `docs/cross-candidate-ordering.md` ← 引擎机制知识库
- `docs/2026-10-23-early-commit-benchmark.md`、`docs/2026-10-26-early-commit-performance-analysis.md`

## 运行时布局（与魔虎发行包一致，lua 代码零改动）

- 用户 Rime 目录：`lua/`（模块含 mohu_sentence 垫片）+ `mohu/runtime/libtigerengine.dylib`
  + `mohu/model/mohu-sentence-ngram-v5.bin` + `mohu/data/tiger/tiger.lexicon.txt`
- 引擎句柄按宿主进程生命周期复用；与已安装魔虎共用 `mohu/` 目录（引擎/模型同名共存）。

## 迁移验证补齐（2026-11-10 部署冒烟发现，均 HEAD 版/工作树干净版）

- `punctuation.yaml`（default.yaml 的 __include 依赖）
- `mohu_zrm_sentence_core.schema.yaml`、`mohu_flypy_sentence_core.schema.yaml`
- `mohu_zrm.dict.yaml`、`mohu_flypy.dict.yaml`（各 ~2.4MB，反查依赖链要求编译，
  gitignore 仅磁盘）与 `mohu_{zrm,flypy}_custom_phrases.txt`
- `default.yaml` schema_list 裁剪为仅 tiger（原为魔虎开发版三方案）

隔离部署冒烟：`rime_deployer --build` 于干净用户目录 exit 0，产出
tiger.extended.table/prism/reverse、mohu_zrm/mohu_flypy codes.prism、
mohu_pinyin、mohu_charset 全套，无 error。
