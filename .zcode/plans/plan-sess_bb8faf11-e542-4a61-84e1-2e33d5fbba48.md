# 整句方案独立建仓：从魔虎仓迁出到 整句/ 工作区，对照 lvyww/tiger-sentense-rime 做到双优

## Context

**目标**：在 `/Users/fuchuxuan/输入法/整句/`（当前空目录）建立独立的整句方案项目，做到对 `lvyww/tiger-sentense-rime` 的性能+准确度可证实双优。

**硬约束（用户本次明确）**：**rime-tiger（魔虎）仓库一律不改**——不提交、不暂存、不还原、不删文件，只读。所有整句相关的代码、数据、测试、基准资产**复制**到 整句/ 目录（含工作树上未提交的改进版内容），新目录自成 git 仓库独立演进。

**盘点到的关键事实**：
- 魔虎仓中「虎码·整句」已基本成型：`tiger.schema.yaml` + `tiger_sentence_native/` 原生引擎（V5 三元模型 389MB）+ `lua/tiger_mode_proc.lua` 提前上屏；2026-10-26 十万句基准对本地旧包（TCSKNM02）已 99.711% vs 98.007% 双胜。
- 工作树未提交的整句改进（tracker+静态复核+TSC1 紧凑 ABI+缓存分离）已三轮报告验证：CPU 3.661→1.639ms、行为零差异、误提前 76→73 句——**必须以工作树版本带走**（只 `git show`/`cp`，不写回）。
- 从未直接测过 lvyww 仓库（五阶 TCSKNM03 405MB + 邻键纠错 + 自动选重），「更胜一筹」需要同口径实测。
- 魔虎仓另有一条与整句无关的半成品反查改动（mohu_zrm/flypy schema、已删的 mohu_pinyin.dict.yaml）——**不带走**；若闭环需要这些文件，用 `git show HEAD:` 版本取干净内容。

## Phase 0 — 搬迁：整句工作区自立（纯读魔虎仓）

目标结构（`/Users/fuchuxuan/输入法/整句/`）：

```
整句/
├── .git/                      # 新仓，首提交=导入快照
├── PROVENANCE.md              # 来源清单：魔虎仓路径 + git HEAD 56fb959 + 带走的未提交文件列表
├── tiger.schema.yaml          # 工作树版（含 all_ranks/early_commit 等未提交改动）
├── tiger.dict.yaml            # 工作树版
├── rime.lua                   # 根注册入口
├── lua/                       # 整个 lua/ 目录（魔虎框架 + tiger_mode_proc/tiger_reverse_mode/tiger_progress_hint/tiger_rank.txt）
├── tiger_sentence_native/     # 整目录：引擎源码、dylib(351,696B 工作树版)、lexicon、模型 bin+zip、lua-5.4.6、build.sh、eval、README
├── mohu_defs.yaml / symbols.yaml / default.yaml
├── opencc/                    # schema 引用到的（emoji 等）
├── mohu_charset.dict.yaml + mohu_charset.schema.yaml        # 扩展字集
├── mohu_pinyin.dict.yaml(取 HEAD 版) + mohu_pinyin.schema.yaml + mohu_pinyin_speller.yaml  # 反查闭环，缺什么补什么
├── tests/                     # 整句+框架相关：tiger_mode_proc/progress_hint/static_compact/early_learning_test.lua、tigerengine_safety/lua_safety_test.cc、test_mohu_tiger_sentence_native.py、mohu 框架 filter 测试
├── Makefile                   # 精简版：lua 测试 + tigerengine 测试 + dylib 构建（不搬魔虎码表机器）
├── bench/                     # 基准资产
│   ├── 100k/                  # 复制 docs/reports/2026-10-26-tiger-100k-comparison/ 五脚本
│   ├── error-replay/          # 复制 docs/reports/2026-10-27-error-replay/（含 build_error_corpus.py）
│   ├── perf-final/ rerun/ search-opt/   # 三轮参考报告
│   ├── build_bench_corpus.py  # 取自 tools/
│   └── corpus/fenci/          # 从 research/lm_sentence_compare/corpus/fenci/ 复制（先查体积；过大则记录只读引用路径，基准脚本指向魔虎仓原位读取）
└── docs/                      # 整句相关报告与 tiger_sentence_native 文档副本
```

执行要点：
1. 逐项 `cp` 工作树版本；`mohu_pinyin.dict.yaml` 等被无关半成品污染的文件用 `git -C <魔虎仓> show HEAD:<path>` 取干净版（git 只读操作）。
2. `tiger.schema.yaml` 的 `dependencies`（mohu_zrm/mohu_flypy/mohu_pinyin/mohu_charset）逐个核对真实用途，只搬编译闭环真正需要的；以隔离编译验证为准，不搬 83MB 的 words 大表（整句引擎不读它）。
3. `git init` + 首提交；PROVENANCE.md 记录每个来源文件是 HEAD 版还是工作树版。

**Phase 0 验证（出口条件）**：
- 新仓内 `make test`（lua 单测全绿：tiger_mode_proc/tiger_progress_hint/tiger_static_compact/tiger_early_learning + 框架 filter 测试）；python 测试可跑。
- dylib 能在新仓用 `build.sh` 重建（tiger_sentence_native 自带 lua-5.4.6 头）。
- **隔离部署冒烟**：临时用户目录 + rime_deployer（可从 `/Users/fuchuxuan/输入法/librime` 构建产物或 Squirrel 取）编译 tiger 方案成功，产出 table/prism；无 `error building config`。
- 魔虎仓 `git status` 与搬迁前逐字节一致（未被动过）。

## Phase 1 — lvyww/tiger-sentense-rime 接入十万句基准

1. `git clone https://github.com/lvyww/tiger-sentense-rime` 到 `整句/competitors/tiger-sentense-rime/`，下载其五阶模型（~405MB，记 SHA-256）。第三方代码按不可信数据处理：只被基准 driver 以桩环境加载，不在其中跑解释器/构建。
2. 在 `bench/100k/` 基础上出新一轮脚本（产物落 `bench/reports/2026-11-XX-lvyww-100k/`）：
   - `prepare.py`：staging `lvyww/`（其 lua/、rime.lua、codes.txt、char_ranks.txt、whitelist、models、schema、supplement）；语料池按 `build_bench_corpus.py` 同法从 fenci 重建 79 万句；共同 rank-1 字集改为「我方 tiger.dict.yaml × lvyww codes.txt」交集；同 seed 抽 10 万句；manifest 记录三方哈希。
   - `driver.lua`：新增 mode `lvyww`——仿 original 分支 require 其引擎 + 最小 rime_api 桩（`get_user_data_dir`）；其 processor/translator 所需 env 面逐步扩桩，收尾解码走其自身接口。**时间盒 1 天**，超时降级为「我方重跑 + lvyww 单独跑」分开口径并在报告注明。
   - `aggregate.py`/`report.py`：三方（我方/lvyww/旧包）配对统计，口径沿用：最终首选准确率、误提前上屏率、自动覆盖率、未上屏键分布、逐键 CPU P50/90/99。
3. 三方同语料跑完（lvyww 纯 Lua 慢，8 片并行后台），落权威报告（manifest+artifacts sha256+early-errors+paired-differences）。

## Phase 2 — 差距分析与增强（按 Phase 1 实测分档，改动全部在新仓）

- 已双胜（准确率 ≥ lvyww 且 CPU ≤ 其 1/2）→ 直接 Phase 3。
- 否则按差距选做，每项走「error-replay 子集回归 → 十万句全量复测 → CPU 表」闭环：
  1. **五阶模型**（若其上下文优势明显）：tigerengine.cc 增五阶读取器（格式见其 docs/TCSKNM03.md；GPL-3 仓，格式重实现合法；其模型文件仅本地基准、不随包分发），或用 fenci 语料自训五阶（沿用 V5 训练去重口径）。
  2. **错句攻坚**：73 误提前 + ~286 最终错按类归因（模型排序/码表缺词/阈值边界），补 supplement 词表、调 word_edge/text_lexicon 权重、复核强档门槛。
  3. **可选功能对齐**（准确度已胜且有余力才做）：同排邻键纠错、自动选重——独立开关默认关，不进验收硬指标。

## Phase 3 — 独立仓发布成型

新仓本身就是 tiger-sentense-rime 式的独立项目：README（安装/模型放置/开关说明 + 三方对照报告作为双优实证）、安装 zip（方案+lua+引擎 runtime+码表；模型走 Release 附 SHA-256）、版本化 schema。终验：干净用户目录模拟安装 + 冒烟键序 + 模型缺失回退路径。

## 风险与说明

- **闭环完整性**是搬迁最大风险：以隔离编译+单测为准逐个补缺，宁可多拷 opencc/小表，不拷 83MB words 大表。
- 与已装魔虎共用用户目录 `mohu/` runtime 路径（引擎/模型同名共存）：初期保持零代码改动，README 说明共存关系；后续如需独立目录再改配置。
- 新共同语料与 2026-10-26 报告不可横比（共同字集变化），报告双列注明；语料与训练集同源沿既有口径标注「训练重叠测评」。
- lvyww 接入 env 面适配设时间盒与降级口径。
- 魔虎仓保持只读：所有 `git` 操作仅限 `show`/`status`/`diff` 类读取。
