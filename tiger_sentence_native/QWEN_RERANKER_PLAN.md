# 魔虎整句本地 Qwen 评分重排 Implementation Plan

> 当前产品取舍（2026-08-28）：提前上屏已移除。本文中涉及
> `try_early_commit`、提前提交状态机或相关开关的段落属于历史设计记录，
> 不再是运行时要求；当前实现只生成候选并进行可选神经重排。

## 执行版修订（2026-08-26）

本计划最初以 llama.cpp/GGUF 为候选实现；根据用户固定的
`Qwen3.5-0.8B` 目标、当前 Apple Silicon 环境和实测结果，实际执行版固定为
`mlx-community/Qwen3.5-0.8B-MLX-4bit`（revision
`5d894f8cc4ef3e6c88537bf3746ed262f549da6a`）。以下约束覆盖原计划中尚未执行的
GGUF、llama.cpp、C++ scorer service 和 Windows transport 小节：

- scorer 使用 `mlx-lm==0.31.3` 的 Qwen3.5 文本分支；模型权重只在独立 Python
  进程中加载，Rime 宿主不链接 MLX。
- 每次请求对 native shortlist（默认 5，必要时最多 20）做一次 batched causal likelihood；`sum_logp` 只累加
  候选 token，不加入 EOS，`predicted_tokens` 必须大于零。这样不会把“是否已经
  结束句子”混入仍在输入中的临时候选。
- 生产传输是用户目录下权限为 `0600` 的 Unix JSONL socket。launchd 负责预启动、
  预热和重启 scorer；Lua translator 不在按键线程中启动进程，也不执行 curl、
  prompt 生成或伪分数 fallback。
- profile 只接受 schema 1、受限的 `base_top_k`/`max_top_k`、`sum_token_logp`/`mean_token_logp`，并
  固定模型目录指纹；任一 hash、协议、分数或 deadline 校验失败都保留三元原序。
- 当前实测（Apple Silicon、4-bit、预热后、5 行快路径）
  P50/P95/P99/max 约为 `28/29/30/32 ms`；adaptive 20 行通常约 `55-65 ms`，
  因此分别使用 `45 ms` 与 `140 ms` deadline，并将重排触发下限设为 8 个原始码字符。固定 batch 行避免 MLX
  量化 kernel 因候选数量改变而产生不同分数。该数据不宣称 Gate A 的统计准确率
  通过；完整语料仍需单独提供。

## 当前实现状态（2026-08-27）

以下执行结果 supersede the earlier draft assumptions in the historical task
sections below：

- 生产模型是本地 `Qwen3.5-0.8B-MLX-4bit`，通过私有 Unix JSONL socket 运行；
  不要求用户提供 adapter/profile，profile 随方案安装并固定 checkpoint 指纹。
- native translator 默认先取 5 条；当 native margin/分支多样性达到阈值时，
  在传输前一次性扩到最多 20 条。不会在停顿后循环追加请求；未评分尾部保留
  native 顺序。
- scorer 对 `<=5` 条使用 5 行 kernel，对 `>5` 条内部补齐 20 行，短序列和
  target projection 至少补到 8 token。不同更长 sequence bucket 仍可能有量化
  数值漂移，因此只在同一请求内比较分数。
- `tiger/rerank_timeout_ms=45` 只用于 5 行快路径，`tiger/rerank_full_timeout_ms=140`
  用于扩展请求；超时、模型不匹配或服务不可用均 fail-open。
- 提前上屏功能在当前版本已移除；神经重排只改变候选顺序，任何 scorer
  超时、模型不匹配或服务不可用都保持原始组合，不主动提交文本。
- C 引擎增量缓存会在 terminal 多字状态、无效 raw 或模式切换时失效；最终
  EOS/isolation 调整后才截断 top-20，early 列表也有显式 cap/truncated 标志。

计划中仍保留的“神经开启即禁用提前上屏”“固定 top-5”文字是原始方案草稿，
不代表当前代码行为；以本节、`README.md` 和 `eval/latest-report.md` 为准。

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox syntax for tracking.

**Goal:** 在不破坏现有三元解码、魔虎候选流水线和失败降级行为的前提下，用本地 Qwen Base 模型对原生整句 shortlist（默认 top-5、必要时 top-20）计算序列分数，并提升整句首选正确率。

**Architecture:** 三元引擎继续生成 top-20 及 score/confidence/segmented。独立 scorer 进程常驻加载本地 MLX checkpoint，通过本机私有 Unix JSONL socket 同步返回 shortlist 连续分数；Lua translator 在创建 mohu_tiger_sentence Candidate 前融合分数并稳定排序。Rime 没有已验证的异步候选刷新入口，因此保持同步、有界、fail-open；服务未就绪、超时或响应非法时保留三元原序。

**Tech Stack:** C++17、llama.cpp、Lua 5.4/librime-lua、Python 3/uv、CMake、macOS Unix domain socket、Windows named pipe、Squirrel/Weasel。

---

## 1. 已确认事实

### 当前魔虎原生整句

~~~text
Squirrel + librime-lua
  -> tiger_sentence_native/mohu_tiger_sentence.lua
  -> package.loadlib(tiger/libtigerengine.dylib)
  -> TCSKNM01/02 + 增量 beam=200
  -> top-20 原生整句候选
  -> Candidate(type="mohu_tiger_sentence")
  -> 魔虎既有 filters
~~~

- C 输出已经包含完整句子、分段、三元 score、聚合 confidence、档位和 pathmap。
- Lua 在 decoded.items 阶段仍持有这些字段；转换为 Rime Candidate 后会丢失 score/confidence。
- 原生候选已有独立 type，不再与普通 sentence 候选混淆。
- 当前版本不注册提前上屏的 update_notifier；候选确认交给 Rime 默认编辑器。
- 动态库不可用或解码失败时，默认魔虎 translator 继续提供候选。

### TigerClaw Windows 参考实现

反编译安装包得到的实际链路：

~~~text
TigerClaw.Core.exe
  -> 三元 top-20
  -> 深度 1 后台队列
  -> named pipe
  -> TigerClaw.Sentence.exe 独立进程
  -> Native.dll + llama.cpp CPU
  -> Qwen3-0.6B-Base Q8 返回 score[5]
  -> 校验 seq + generation + rawCode
  -> FinalScore = BaseScore + 0.84 * neuralScore
  -> 重排前 5
  -> PublishUiState() 更新自有候选窗
~~~

旧方案必须据此修正：

1. TigerClaw 不用 prompt 生成序号，而是直接计算候选序列分数。
2. TigerClaw 不用 HTTP、Ollama 或 llama-server，而是独立 scorer 加私有命名管道。
3. TigerClaw 异步生效依赖它拥有候选窗和 PublishUiState()；该条件在 Rime Lua filter 中不存在。
4. TigerClaw 整句模式不提前上屏；神经结果未返回时，空格提交三元当前首选。

## 2. 第一性原理决策

### 问题本质

目标是提高用户实际看到并提交的首选，不是“接入 LLM”。以下条件必须同时成立：

- 正确答案位于 top-k；
- 神经排序在独立测试集上的净收益为正；
- 候选生成不出现可感知卡顿；
- scorer 缺失、冷启动、超时和崩溃时行为等于当前基线；
- 显示首选和自动提交不能来自互相冲突的排序源。

### 选定方案

- **评分：** Base 模型逐候选 token likelihood；禁止 chat template、sampling 和文本生成。
- **融合：** final_score = base_score + alpha * neural_score；alpha 由开发集标定。
- **位置：** 在 mohu_tiger_sentence.lua 的 decoded.items 阶段重排，只影响原生
  adaptive shortlist（默认前 5，必要时扩到前 20）。
- **调用：** translator 内有界同步 IPC，使首轮 Candidate 就是最终显示顺序。
- **隔离：** llama.cpp 和 GGUF 位于独立 scorer 进程，不进入 Squirrel/Weasel 主进程。
- **提前上屏：** 与神经开关独立；有界列表使用显式 opt-in 的 confidence heuristic，
  完整共识摘要仍优先。
- **默认：** 神经重排默认关闭；核心方案不依赖模型包。

### 否决方案

| 方案 | 原因 |
|---|---|
| Lua filter 异步 submit/poll | 后台完成不会主动重跑 Rime filter |
| OpenAI API prompt 输出 0-4 | 有生成、解析、拒答和 prompt 漂移，不能连续融合先验 |
| 正式版把模型静态链入 libtigerengine | 大内存和崩溃生命周期进入输入法宿主 |
| 自动复用 Ollama/oMLX | 模型、模板、分数和隐私边界不可复现 |
| 未验证收益先分发 GGUF | 先承担 0.5-1GB 成本，尚无效果证据 |

## 3. 阶段门槛

任一 Gate 失败即停止后续阶段，保留可复现报告，不转向无刷新异步 filter。

### Gate A: 可提升空间和准确率

- 真实码形 top-5 oracle 相对 baseline top-1 至少有 0.5 个百分点空间。
- 独立测试集 top-1 至少提升 0.30 个百分点。
- 10,000 次配对 bootstrap 的 95% CI 下界大于 0。
- 任一预定义切片下降不超过 0.20 个百分点。
- najqmzufmekeybyudele 首选变为“那就没什么可犹豫的了”。

### Gate B: scorer 内核延迟

执行版实测五候选 P50/P95/P99/max 为 `27.743/28.244/28.513/38.694 ms`，所以原始 Gate B
阈值在当前机器上明确 **FAIL**。按键路径仍保持神经开关默认关闭，并只作为本地
opt-in 功能部署；未达到该门槛前不把它纳入正式发行默认配置。

目标 Apple Silicon、模型预热、top-5 批量评分：

- P50 <= 8ms；
- P95 <= 12ms；
- P99 <= 20ms；
- max <= 50ms。

依次评测 Qwen3.5-0.8B-Base Q8、Q4_K_M 和 Qwen3-0.6B-Base Q8。全部失败则不进入 Rime。

### Gate C: macOS Rime 全链路

从按键进入 librime 到候选可读的增量：

- ready: P95 <= 15ms、P99 <= 25ms；
- missing/not-ready: P99 增量 <= 1ms；
- 冷启动不阻塞按键，就绪前使用三元原序；
- scorer 卡死时等待不超过配置 deadline。
- 同一测试集经完整 librime pipeline 后，用户可见 top-1 的净提升仍满足 Gate A；固定、pin、custom phrase 和 smart 的既有优先级不变。

### Gate D: Windows

- 官方 Weasel x64 可 package.loadlib 最小 Lua 5.4 DLL；
- 2,000 句两种策略与 macOS 三元输出逐字节一致；
- scorer ready: P95 <= 20ms、P99 <= 35ms；
- 不达标时 Windows 神经开关继续默认关闭。

## 4. 文件边界

### 现有文件

| 文件 | 责任 |
|---|---|
| tiger_sentence_native/tigerengine.cc | 三元模型、beam、C ABI |
| tiger_sentence_native/tigerengine_lua.cc | Lua 5.4 绑定 |
| tiger_sentence_native/mohu_tiger_sentence.lua | translator、重排策略（提前上屏已移除） |
| tiger_sentence_native/mohu_tiger_sentence.schema.yaml | 开关和配置 |
| tests/mohu_tiger_sentence_native_test.lua | Lua 行为 |
| tests/test_mohu_tiger_sentence_native.py | schema 结构 |

### 新增文件

| 文件 | 责任 |
|---|---|
| tiger_sentence_native/tigerengine.h | 唯一 C ABI 声明 |
| tiger_sentence_native/tiger_rerank_policy.h/.cc | 分数校验、融合、稳定 top-k 排序 |
| tiger_sentence_native/tiger_scorer.h | scorer 抽象 |
| tiger_sentence_native/tiger_scorer_llama.cc | llama.cpp token likelihood |
| tiger_sentence_native/tiger_scorer_protocol.h | 有界二进制 IPC |
| tiger_sentence_native/tiger_scorer_client.h/.cc | ready 探测、同步 deadline、fail-open |
| tiger_sentence_native/tiger_scorer_service.cc | 独立进程和模型生命周期 |
| tiger_sentence_native/tiger_scorer_transport_posix.cc | posix_spawn + Unix socket |
| tiger_sentence_native/tiger_scorer_transport_windows.cc | CreateProcessW + named pipe |
| tiger_sentence_native/tiger_scorer_bench.cc | scorer 分位延迟 |
| tiger_sentence_native/CMakeLists.txt | macOS/Windows 构建 |
| tools/evaluate_tiger_reranker.py | dump、oracle、标定、bootstrap |
| tests/test_tiger_reranker_eval.py | 评测逻辑单测 |
| tests/fixtures/tiger_reranker_cases.jsonl | 小型回归集 |
| tests/tiger_rerank_policy_test.cc | C++ policy/protocol 单测 |
| tiger_sentence_native/eval/corpus-manifest.json | 大语料来源、条数、SHA-256 |
| tiger_sentence_native/mohu_tiger_reranker_profile.lua | Task 4 生成的模型哈希和参数 |

## 5. 实施任务

### Task 1: 建立可复现评测契约

**Files:**
- Create: tools/evaluate_tiger_reranker.py
- Create: tests/test_tiger_reranker_eval.py
- Create: tests/fixtures/tiger_reranker_cases.jsonl
- Create: tiger_sentence_native/eval/corpus-manifest.json

- [ ] **Step 1: 写失败测试**

~~~python
import unittest

from tools.evaluate_tiger_reranker import evaluate_rows


class TigerRerankerEvalTest(unittest.TestCase):
    def test_counts_corrections_harms_and_oracle(self) -> None:
        rows = [
            {"expected": "乙", "candidates": [{"text": "甲"}, {"text": "乙"}],
             "reranked": ["乙", "甲"]},
            {"expected": "甲", "candidates": [{"text": "甲"}, {"text": "乙"}],
             "reranked": ["乙", "甲"]},
        ]
        metrics = evaluate_rows(rows)
        self.assertEqual(1, metrics.baseline_correct)
        self.assertEqual(1, metrics.reranked_correct)
        self.assertEqual(1, metrics.corrections)
        self.assertEqual(1, metrics.harms)
        self.assertEqual(2, metrics.oracle_correct)
~~~

- [ ] **Step 2: 确认失败**

Run: uv run python -m unittest tests.test_tiger_reranker_eval -v

Expected: FAIL，模块尚不存在。

- [ ] **Step 3: 实现两个固定 JSONL schema**

原始 case 文件只描述可复现输入和答案：

~~~json
{"id":"case-1","source":"lccc","mode":"real_aux","raw":"...","expected":"..."}
~~~

dump 文件在同一记录上增加 candidates；每个 candidate 固定包含 text/base_score/confidence/segmented。evaluate_rows 只接收 dump 记录，返回 baseline、reranked、oracle、corrections、harms，以及 source/mode/raw_length_band 切片。bootstrap 固定 seed=20260826、samples=10000。

- [ ] **Step 4: 加入目标回归**

~~~json
{"id":"de-di-de-001","source":"regression","mode":"real_aux","raw":"najqmzufmekeybyudele","expected":"那就没什么可犹豫的了"}
~~~

- [ ] **Step 5: 生成 manifest**

~~~bash
uv run tools/evaluate_tiger_reranker.py manifest \
  --news "$MOHU_RERANK_NEWS_CORPUS" \
  --lccc "$MOHU_RERANK_LCCC_CORPUS" \
  --output tiger_sentence_native/eval/corpus-manifest.json
~~~

Expected: 记录来源、行数、SHA-256、许可备注和日期；不提交 corpus 正文。

- [ ] **Step 6: 验证并提交**

~~~bash
uv run python -m unittest tests.test_tiger_reranker_eval -v
git add tools/evaluate_tiger_reranker.py tests/test_tiger_reranker_eval.py \
  tests/fixtures/tiger_reranker_cases.jsonl tiger_sentence_native/eval/corpus-manifest.json
git commit -m "test: add sentence reranker evaluation harness"
~~~

### Task 2: 抽取 C ABI 和纯重排策略

**Files:**
- Create: tiger_sentence_native/tigerengine.h
- Create: tiger_sentence_native/tiger_rerank_policy.h
- Create: tiger_sentence_native/tiger_rerank_policy.cc
- Create: tests/tiger_rerank_policy_test.cc
- Modify: tiger_sentence_native/tigerengine.cc
- Modify: tiger_sentence_native/tigerengine_lua.cc

- [ ] **Step 1: 写融合测试**

~~~cpp
std::vector<RerankItem> items = {
    {"甲", -10.0, -2.0, 0},
    {"乙", -10.1, -1.0, 1},
    {"丙", -12.0, -0.5, 2},
};
auto ranked = BlendAndRank(items, 0.84, 2);
assert(ranked[0].text == "乙");
assert(ranked[1].text == "甲");
assert(ranked[2].text == "丙");
~~~

同时覆盖 NaN、无穷、数量不符、相同 final score 稳定 tie-break、top-k 之后不动。

- [ ] **Step 2: 确认失败**

~~~bash
clang++ -std=c++17 -I tiger_sentence_native tests/tiger_rerank_policy_test.cc \
  tiger_sentence_native/tiger_rerank_policy.cc -o /tmp/tiger-rerank-policy-test
~~~

Expected: FAIL，header/implementation 尚不存在。

- [ ] **Step 3: 定义唯一 C ABI**

~~~cpp
extern "C" {
int tiger_engine_create(const char*, const char*, int, int, char*, int);
void tiger_engine_free(int);
int tiger_decode(int, const char*, int, char*, int, double*);
int tiger_status(int, char*, int);
const char* tiger_last_error();
}
~~~

两份 C++ 文件 include tigerengine.h，删除重复 extern。

- [ ] **Step 4: 实现 BlendAndRank**

规则：先验证全部 neural score；任一非法则返回原序；只融合前 top_k；以 original_index 稳定打破平分；后续候选保持原位。

- [ ] **Step 5: 验证并提交**

~~~bash
/tmp/tiger-rerank-policy-test
git add tiger_sentence_native/tigerengine.h tiger_sentence_native/tiger_rerank_policy.* \
  tiger_sentence_native/tigerengine.cc tiger_sentence_native/tigerengine_lua.cc \
  tests/tiger_rerank_policy_test.cc
git commit -m "feat: add deterministic sentence rerank policy"
~~~

### Task 3: 实现离线 llama.cpp Base scorer

**Files:**
- Create: tiger_sentence_native/tiger_scorer.h
- Create: tiger_sentence_native/tiger_scorer_llama.cc
- Create: tiger_sentence_native/tiger_scorer_bench.cc
- Create: tiger_sentence_native/CMakeLists.txt
- Create: .gitmodules

- [ ] **Step 1: 固定依赖和模型 revision**

- llama.cpp: dac869b0a05d14073d174f330bcd86b9122df549
- Qwen3-0.6B-Base: da87bfb608c14b7cf20ba1ce41287e8de496c0cd
- Qwen3.5-0.8B-Base: dc7cdfe2ee4154fa7e30f5b51ca41bfa40174e68

GGUF 通过 MOHU_QWEN_MODEL 提供，不进 git。正式候选 GGUF 必须由上述 Hugging Face revision 使用本任务固定的 llama.cpp converter/quantizer 生成；第三方 GGUF 只能用于对照，不能成为发布 profile。TigerClaw 模型只用于本地参考，不得再分发。

~~~bash
git submodule add https://github.com/ggml-org/llama.cpp.git tiger_sentence_native/third_party/llama.cpp
git -C tiger_sentence_native/third_party/llama.cpp checkout dac869b0a05d14073d174f330bcd86b9122df549
~~~

- [ ] **Step 2: 定义 scorer**

~~~cpp
struct SentenceScore {
  double sum_logp;
  uint32_t predicted_tokens;
};

class SentenceScorer {
 public:
  virtual ~SentenceScorer() = default;
  virtual bool Score(const std::vector<std::string>& texts,
                     std::vector<SentenceScore>* scores,
                     std::string* error) = 0;
};

std::unique_ptr<SentenceScorer> CreateLlamaSentenceScorer(
    const std::string& model_path, int threads, bool use_gpu,
    std::string* error);
~~~

- [ ] **Step 3: 实现确定性 likelihood**

~~~text
start = BOS when defined, otherwise EOS
tokens = start + tokenize(candidate) + EOS
token_logp[i] = log_softmax(logits_at_i)[tokens[i + 1]]
sum_logp = sum(token_logp)
predicted_tokens = count(token_logp)
~~~

一次 batch 包含 1..5 个独立 sequence；start token 不计入 predicted_tokens，候选 token 和末尾 EOS 计入。候选非空、每项 <= 512 bytes、总 token 不超过 context/batch。禁止 sampling、chat template 和生成。相同输入重复 100 次必须逐位相等。

- [ ] **Step 4: 构建基准**

~~~bash
cmake -S tiger_sentence_native -B /tmp/mohu-tiger-build \
  -DMOHU_LLAMA_DIR="$PWD/tiger_sentence_native/third_party/llama.cpp"
cmake --build /tmp/mohu-tiger-build --target tiger_scorer_bench
MOHU_QWEN_MODEL="$MOHU_QWEN_MODEL" \
  /tmp/mohu-tiger-build/tiger_scorer_bench --warmup 20 --runs 500 \
  --json-out /tmp/mohu-rerank-bench.json \
  --candidate 那就没什么可犹豫地了 \
  --candidate 那就没什么可犹豫的了
~~~

Expected: 输出模型 SHA-256、有限 sum/mean score、P50/P95/P99/max 和峰值 RSS，并写入 /tmp/mohu-rerank-bench.json。

- [ ] **Step 5: 验证边界并提交**

空候选、6 个候选、超长候选必须返回错误而不崩溃。

~~~bash
git add .gitmodules tiger_sentence_native/third_party/llama.cpp \
  tiger_sentence_native/tiger_scorer.h tiger_sentence_native/tiger_scorer_llama.cc \
  tiger_sentence_native/tiger_scorer_bench.cc tiger_sentence_native/CMakeLists.txt
git commit -m "feat: add local Qwen sentence scorer"
~~~

### Task 4: 离线标定模型、公式和触发阈值

**Files:**
- Modify: tools/evaluate_tiger_reranker.py
- Create: tiger_sentence_native/eval/latest-report.md
- Create: tiger_sentence_native/mohu_tiger_reranker_profile.lua

- [ ] **Step 1: 导出三元 top-20**

~~~bash
uv run tools/evaluate_tiger_reranker.py dump \
  --engine tiger_sentence_native/libtigerengine.dylib \
  --model "$MOHU_TIGER_NGRAM_MODEL" \
  --lexicon tiger_sentence_native/mohu_tiger.lexicon.txt \
  --cases "$MOHU_RERANK_CASES" \
  --output /tmp/mohu-rerank-candidates.jsonl
~~~

- [ ] **Step 2: 生成模型分数**

分别评测 Qwen3-0.6B-Base Q8、Qwen3.5-0.8B-Base Q8/Q4_K_M。每个候选输出 sum_logp 和 predicted_tokens，并携带 GGUF SHA-256。

- [ ] **Step 3: 固定数据切分**

按 source + mode 分层，以 seed=20260826 做 80/20 开发/测试切分。测试集只运行一次最终 profile。

- [ ] **Step 4: 网格搜索**

~~~text
normalization in {sum_token_logp, mean_token_logp}
alpha         in {0.0, 0.1, ..., 1.5}
min_raw_len   in {4, 6, 8}
max_conf_gap  in {0.25, 0.5, 1.0, 2.0, infinity}
top_k         = 5
~~~

主目标为开发集 top-1；并列时依次选择 harms 少、alpha 小、触发少的 profile。

- [ ] **Step 5: 生成不可手改的 profile**

脚本只在 Gate A/B 的统计前置条件全部满足时生成 Lua table。必需字段及约束为：schema 必须等于 1；model_sha256 必须是实际 GGUF 的 64 位小写十六进制；normalization 必须是网格中的枚举值；alpha 必须是获胜的正数；top_k 必须等于 5；min_raw_len 和 max_conf_gap 必须是获胜阈值。Task 7 不允许在 schema 再维护第二份参数。

- [ ] **Step 6: 执行 Gate A/B**

~~~bash
uv run tools/evaluate_tiger_reranker.py calibrate \
  --candidates /tmp/mohu-rerank-candidates.jsonl \
  --scores /tmp/mohu-rerank-scores.jsonl \
  --benchmarks /tmp/mohu-rerank-bench.json \
  --profile tiger_sentence_native/mohu_tiger_reranker_profile.lua \
  --report tiger_sentence_native/eval/latest-report.md
~~~

Expected: Gate A/B 全部 PASS。任一 FAIL 时停止 Task 5 及以后。

- [ ] **Step 7: 提交报告和 profile**

~~~bash
git add tools/evaluate_tiger_reranker.py \
  tiger_sentence_native/mohu_tiger_reranker_profile.lua \
  tiger_sentence_native/eval/latest-report.md
git commit -m "feat: add calibrated sentence reranker profile"
~~~

### Task 5: 定义并测试本地 scorer IPC

**Prerequisite:** Gate A/B PASS。

**Files:**
- Create: tiger_sentence_native/tiger_scorer_protocol.h
- Create: tiger_sentence_native/tiger_scorer_client.h
- Create: tiger_sentence_native/tiger_scorer_client.cc
- Create: tiger_sentence_native/tiger_scorer_service.cc
- Create: tiger_sentence_native/tiger_scorer_transport_posix.cc
- Create: tests/tiger_scorer_protocol_test.cc
- Modify: tiger_sentence_native/CMakeLists.txt

- [ ] **Step 1: 写 frame round-trip 测试**

~~~cpp
struct FrameHeader {
  uint32_t magic;        // 0x4d545252, "MTRR"
  uint16_t version;      // 1
  uint16_t type;         // ping=1, score=2, response=3, shutdown=4
  uint64_t request_id;
  uint32_t payload_size;
};
~~~

score payload: candidate_count + 重复的 byte_length/UTF-8 bytes。score response: status + score_count + 重复的 little-endian IEEE754 sum_logp 与 uint32 predicted_tokens + error_length/error。ping response 还必须携带 32-byte model SHA-256 和 scorer build id。payload <= 8KiB。

- [ ] **Step 2: 确认失败**

Run: cmake --build /tmp/mohu-tiger-build --target tiger_scorer_protocol_test

Expected: FAIL，协议尚不存在。

- [ ] **Step 3: 实现 POSIX transport**

- runtime 目录 0700、socket 0600；endpoint 由当前 uid、parent pid 和期望模型哈希确定；
- posix_spawn 启动，禁止 shell；
- init 只启动，不等待模型；
- scorer 在后台计算实际 GGUF SHA-256；与期望值一致并加载成功后才创建 socket；
- Score 使用 monotonic deadline；
- candidate 文本不写日志或命令行。

- [ ] **Step 4: 实现生命周期**

服务加载一次模型；父进程消失或空闲 10 分钟退出。一次连接一个请求，评分串行。客户端超时断开后丢弃完成结果，不给下一请求复用。并发 configure 必须通过 endpoint/lock 保证同一 parent/model 只留下一个服务实例。

- [ ] **Step 5: 覆盖 fail-open**

测试服务缺失、模型缺失、冷启动、半帧、超长 frame、错误 request id、score 数不符、NaN、服务退出、50ms 假 scorer 被 10ms deadline 截断。

- [ ] **Step 6: 验证并提交**

~~~bash
cmake --build /tmp/mohu-tiger-build --target tiger_scorer_protocol_test
/tmp/mohu-tiger-build/tiger_scorer_protocol_test
git add tiger_sentence_native/tiger_scorer_protocol.h \
  tiger_sentence_native/tiger_scorer_client.* \
  tiger_sentence_native/tiger_scorer_service.cc \
  tiger_sentence_native/tiger_scorer_transport_posix.cc \
  tiger_sentence_native/CMakeLists.txt tests/tiger_scorer_protocol_test.cc
git commit -m "feat: add isolated sentence scorer service"
~~~

### Task 6: 暴露 scorer C ABI 和 Lua API

**Files:**
- Modify: tiger_sentence_native/tigerengine.h
- Modify: tiger_sentence_native/tigerengine.cc
- Modify: tiger_sentence_native/tigerengine_lua.cc
- Modify: tests/mohu_tiger_sentence_native_test.lua

- [ ] **Step 1: 扩展 fake module 测试**

~~~lua
configure_reranker = function(_, service, model, expected_sha256, timeout_ms)
  assert(service:match("tiger%-scorer"))
  assert(model:match("[.]gguf$"))
  assert(expected_sha256:match("^[0-9a-f]+$") and #expected_sha256 == 64)
  assert(timeout_ms == 20)
  return true
end,
score = function(_, texts)
  assert(#texts == 2)
  return {
    { sum_logp = -6.0, predicted_tokens = 3 },
    { sum_logp = -2.0, predicted_tokens = 2 },
  }, 4.5
end,
~~~

证明 scorer 错误只关闭本次重排，不能设置 engine_error 或停止三元 decode。

- [ ] **Step 2: 确认失败**

Run: lua tests/mohu_tiger_sentence_native_test.lua

Expected: FAIL，接口尚不存在。

- [ ] **Step 3: 增加 C ABI**

~~~cpp
int tiger_rerank_configure(int handle, const char* service_path,
                           const char* model_path,
                           const char* expected_model_sha256,
                           int timeout_ms,
                           char* error, int error_cap);
int tiger_rerank_score(int handle, const char* const* texts, int count,
                       double* sum_logps, uint32_t* predicted_tokens,
                       double* elapsed_ms);
int tiger_rerank_status(int handle, char* out, int out_cap);
~~~

alpha/min length/confidence gap 属于 profile，不进入 C client。score 同步遵守 deadline，并有独立错误域。

- [ ] **Step 4: 增加 Lua API**

~~~lua
t.configure_reranker(handle, service_path, model_path,
                     env.rerank_profile.model_sha256, timeout_ms)
local scores, elapsed_ms = t.score(handle, { "候选一", "候选二" })
assert(scores[1].sum_logp and scores[1].predicted_tokens)
local status = t.rerank_status(handle)
~~~

验证 1..5 个非空字符串、score 数严格相等、sum_logp finite 且 predicted_tokens > 0。只有 ping 返回的实际模型 SHA-256 与 expected_model_sha256 相等时，status 才能进入 ready。

- [ ] **Step 5: 修正生命周期**

translator init 使用模块引用计数；最后一个 fini 调用 t.free(handle) 并清空 module。scorer 由 parent pid/idle timeout 退出，不由单个 schema instance shutdown。

init 只加载和校验 profile，不启动 scorer。第一次满足 should_rerank 的输入才调用 configure_reranker；开关始终关闭的用户不得产生 scorer 进程或 GGUF 内存占用。

- [ ] **Step 6: 验证并提交**

~~~bash
lua tests/mohu_tiger_sentence_native_test.lua
cmake --build /tmp/mohu-tiger-build
git add tiger_sentence_native/tigerengine.h tiger_sentence_native/tigerengine.cc \
  tiger_sentence_native/tigerengine_lua.cc tests/mohu_tiger_sentence_native_test.lua
git commit -m "feat(lua): expose native sentence scoring"
~~~

### Task 7: 在 native translator 内融合分数

**Files:**
- Modify: tiger_sentence_native/mohu_tiger_sentence.lua
- Modify: tiger_sentence_native/mohu_tiger_sentence.schema.yaml
- Modify: tests/mohu_tiger_sentence_native_test.lua
- Modify: tests/test_mohu_tiger_sentence_native.py

- [ ] **Step 1: 写策略失败测试**

覆盖：

1. 开关关闭时不调用 scorer；
2. 少于 2 个候选、raw 太短、confidence gap 超阈值时透传；
3. 合法 sum_logp/predicted_tokens 按 profile 归一化后只重排原生前 5；
4. top-5 之后不动；
5. committed prefix 存在时 scorer 收到完整句子，yield 前才裁前缀；
6. profile 缺失、模型哈希不符、missing/not-ready/timeout/非法 score 保持原序；
7. 神经开启时 try_early_commit 不提交；
8. 同一 raw + top-5 文本重复调用 translator 时只评分一次；
9. filters 不新增 reranker filter。

- [ ] **Step 2: 确认失败**

~~~bash
lua tests/mohu_tiger_sentence_native_test.lua
uv run python -m unittest tests.test_mohu_tiger_sentence_native -v
~~~

- [ ] **Step 3: 保存 header 计数**

parse_output 保存 n_final/n_early，不再二次正则解析完整输出；items/early 行为不变。

- [ ] **Step 4: 增加开关和路径配置**

~~~yaml
- name: mohu_tiger_sentence_neural_rerank
  reset: 0
  states: [ 神经重排关, 神经重排开 ]

tiger:
  rerank_service: tiger/tiger-scorer
  rerank_model: tiger/qwen-sentence.gguf
  rerank_timeout_ms: 20
~~~

top_k、alpha、min_raw_len、max_conf_gap 和模型 SHA-256 只从 mohu_tiger_reranker_profile.lua 读取。profile 文件不存在、字段类型错误或模型哈希非法时，模块记录一次错误并让神经开关成为安全 no-op，三元解码保持可用。

translator.init 使用 pcall(require, "mohu_tiger_reranker_profile") 加载 profile。POSIX 默认 scorer 名为 tiger-scorer；Windows transport 在同一路径追加 .exe，schema 不维护平台分支。

维护最多 64 项的内存 score cache，key 由完整 raw、按序 top-5 文本和模型 SHA-256 组成；只缓存合法响应。commit、外部 reset、profile/model 变化时清空，绝不落盘。

- [ ] **Step 5: Candidate 创建前重排**

~~~lua
local decoded = decode(raw, false)
if should_rerank(raw, decoded, context, env) then
  local texts = top_full_texts(decoded.items, env.rerank_profile.top_k)
  local raw_scores = safe_score(texts, env)
  if raw_scores then
    local scores = normalize_scores(raw_scores, env.rerank_profile.normalization)
    decoded.items = blend_and_stable_sort(
      decoded.items, scores, env.rerank_profile.alpha
    )
  end
end
-- 此后才裁 committed_text 并创建 mohu_tiger_sentence Candidate
~~~

不得改变 fixed、pin、custom phrase、smart 的 quality 或全局 filter 列表。

- [历史废弃] **Step 6: 让提前上屏与神经共存（执行版）**

try_early_commit 不再因神经开关直接返回。完整 beam 使用 C 共识摘要；截断 beam
使用 `visible_consensus` 标记的 bounded confidence heuristic（至少 8 个 raw
字符、三次稳定、共享 raw 边界），神经开关关闭时也适用。该 heuristic 不提供
隐藏路径的形式安全保证。

processor 订阅 option_update_notifier；切换任一开关时清空 evidence，但不替用户改变
另一个开关。关闭神经开关时，用户显式打开的提前上屏继续有效。

- [ ] **Step 7: 验证并提交**

~~~bash
lua tests/mohu_tiger_sentence_native_test.lua
uv run python -m unittest tests.test_mohu_tiger_sentence_native -v
git add tiger_sentence_native/mohu_tiger_sentence.lua \
  tiger_sentence_native/mohu_tiger_sentence.schema.yaml \
  tests/mohu_tiger_sentence_native_test.lua tests/test_mohu_tiger_sentence_native.py
git commit -m "feat(lua): integrate native sentence reranking"
~~~

### Task 8: macOS 全链路验证

**Prerequisite:** Gate A/B PASS，Task 7 完成。

**Files:**
- Modify: tiger_sentence_native/tiger_scorer_bench.cc
- Modify: tools/evaluate_tiger_reranker.py
- Modify: tiger_sentence_native/eval/latest-report.md
- Modify: tiger_sentence_native/README.md

- [ ] **Step 1: 隔离构建部署**

~~~bash
cmake -S tiger_sentence_native -B /tmp/mohu-tiger-build -DMOHU_ENABLE_METAL=ON
cmake --build /tmp/mohu-tiger-build
make dist DESTDIR=/tmp/mohu-rerank-deploy
mkdir -p /tmp/mohu-rerank-deploy/tiger /tmp/mohu-rerank-deploy/lua
cmake --install /tmp/mohu-tiger-build \
  --prefix /tmp/mohu-rerank-deploy/tiger
cp tiger_sentence_native/mohu_tiger_sentence.lua \
  tiger_sentence_native/mohu_tiger_reranker_profile.lua \
  /tmp/mohu-rerank-deploy/lua/
cp tiger_sentence_native/mohu_tiger_sentence.schema.yaml \
  /tmp/mohu-rerank-deploy/
~~~

不得覆盖 ~/Library/Rime。

CMake install rules 必须把 scorer 和动态库放在 prefix 根目录；该命令结束后应存在 tiger/tiger-scorer 与 tiger/libtigerengine.dylib。

- [ ] **Step 2: 验证五种状态**

用 librime probe 覆盖 ready、模型缺失、服务未启动、评分中退出、非法 frame。全部必须保留三元候选，只有 ready 可改原生 top-5。

- [ ] **Step 3: 验证目标句和开关对照**

开启且 ready 时目标句首选正确；关闭时保持基线，证明测试经过重排层。

- [ ] **Step 4: 对拍完整候选流水线**

用同一独立测试集比较 offline native 决策与 librime 用户可见候选。触发重排的 native 子序列必须一致；全局首选变化只允许来自 native top-5 内部重排，既有高优先级候选不得被越过。

- [ ] **Step 5: 测完整链路**

每种状态至少 10,000 次按键，monotonic wall clock 包围完整 librime 调用；报告 P50/P95/P99/max/RSS，不使用 os.clock。

- [ ] **Step 6: 执行 Gate C**

失败时记录模型、量化、profile、机器和分位，并停止 Windows/分发任务。

- [ ] **Step 7: 回归并提交**

~~~bash
make all
make test
git add tiger_sentence_native/tiger_scorer_bench.cc \
  tools/evaluate_tiger_reranker.py tiger_sentence_native/eval/latest-report.md \
  tiger_sentence_native/README.md
git commit -m "docs: record macOS sentence reranker validation"
~~~

make all 若产生大规模无关改写，停止并检查，不提交改写。

### Task 9: Windows 原生引擎和 scorer

**Prerequisite:** Gate C PASS。

**Files:**
- Create: tiger_sentence_native/tiger_platform.h
- Create: tiger_sentence_native/tiger_platform_posix.cc
- Create: tiger_sentence_native/tiger_platform_windows.cc
- Create: tiger_sentence_native/tiger_scorer_transport_windows.cc
- Create: tiger_sentence_native/windows_loadlib_smoke.lua
- Modify: tiger_sentence_native/tigerengine.cc
- Modify: tiger_sentence_native/CMakeLists.txt
- Modify: .github/workflows/build.yml

- [ ] **Step 1: 抽象 POSIX API**

~~~cpp
class ReadOnlyMappedFile {
 public:
  bool Open(const std::string& path, std::string* error);
  const uint8_t* data() const;
  size_t size() const;
};

double MonotonicMilliseconds();
~~~

Windows 使用 CreateFileW/CreateFileMappingW/MapViewOfFile 和 QueryPerformanceCounter。

同时把默认动态库名从硬编码 dylib 改为平台解析：macOS 使用 libtigerengine.dylib，Windows 使用 tigerengine.dll；显式 tiger/engine_lib 配置仍优先。

- [ ] **Step 2: 先做 Weasel loadlib smoke**

~~~lua
local open = assert(package.loadlib("tigerengine.dll", "luaopen_tigerengine"))
assert(open().ping() == "pong")
~~~

未通过不得移植完整引擎。

- [ ] **Step 3: 实现 named pipe**

当前用户 SID 构造 pipe 名和 owner-only ACL；CreateProcessW 启动 scorer，禁止 cmd.exe；overlapped I/O 使用相同 deadline；candidate 不进入日志/命令行。

- [ ] **Step 4: 增加 CI**

公开 CI 覆盖 macos-arm64 和 windows-x64 编译、policy/protocol 单测，不下载 GGUF。真实模型由私有或手工 runner 验证。

- [ ] **Step 5: 对拍并执行 Gate D**

同一 2,000 句两种策略与 macOS 逐字节一致；报告 CPU、线程、模型 SHA-256、量化、延迟和 RSS。

- [ ] **Step 6: 提交**

~~~bash
git add tiger_sentence_native/tiger_platform* \
  tiger_sentence_native/tiger_scorer_transport_windows.cc \
  tiger_sentence_native/windows_loadlib_smoke.lua \
  tiger_sentence_native/tigerengine.cc tiger_sentence_native/CMakeLists.txt \
  .github/workflows/build.yml
git commit -m "build: add Windows native sentence targets"
~~~

### Task 10: 分发、许可和文档

**Prerequisite:** 对应平台 Gate 全部 PASS。

**Files:**
- Modify: tiger_sentence_native/README.md
- Modify: Makefile
- Modify: .github/workflows/build.yml
- Create: tiger_sentence_native/licenses/llama.cpp-LICENSE.txt
- Create: tiger_sentence_native/licenses/Qwen-LICENSE.txt
- Create: tiger_sentence_native/MODEL_MANIFEST.json

- [ ] **Step 1: 固定 manifest**

记录模型 repo/revision/GGUF/SHA-256/量化/字节数/Apache-2.0，以及 llama.cpp commit/MIT。不得分发 TigerClaw 私有代码或二进制。

- [ ] **Step 2: 使用可选增强包**

核心魔虎包不含 GGUF。增强包包含 scorer、模型、notices 和 manifest；不要求 Ollama，不在输入法运行时联网下载。

- [ ] **Step 3: 加入完整性和隐私**

启动前校验模型 SHA-256；IPC 不监听 TCP；不记录输入、候选和上屏内容；错误日志只含状态码、耗时和 build id。

- [ ] **Step 4: 平台签名**

macOS scorer/dylib codesign/notarize；Windows exe/dll 使用发布证书签名；签名后重算发布哈希。

- [ ] **Step 5: 文档化语义**

明确神经默认关闭、模型未就绪自动使用三元原序、关闭开关无需重新部署；提前上屏已从当前产品范围移除。

- [ ] **Step 6: 最终验证和提交**

~~~bash
make all
make test
git status --short
git add Makefile .github/workflows/build.yml tiger_sentence_native/README.md \
  tiger_sentence_native/licenses tiger_sentence_native/MODEL_MANIFEST.json
git commit -m "docs: document local sentence reranker deployment"
~~~

仓库不得包含 GGUF、语料正文、用户输入日志或临时 benchmark 输出。

## 6. 最终验收矩阵

| 维度 | 必须满足 |
|---|---|
| 正确性 | 目标用例修正；测试集净提升和 CI 通过 Gate A |
| 候选边界 | 只重排 mohu_tiger_sentence 的 adaptive shortlist（5..20） |
| 交互 | 神经重排只调整候选顺序；不在输入过程中主动上屏 |
| 延迟 | macOS/Windows 分别通过 Gate C/D |
| 降级 | missing、cold、timeout、crash、bad response 均保留三元原序 |
| 生命周期 | schema reload 不泄漏 handle/thread/process |
| 隐私 | 无 TCP、无候选日志、无运行时下载 |
| 可复现 | corpus/model/llama revision 和 SHA-256 完整 |
| 许可 | llama.cpp/Qwen notices 随增强包 |

## 7. 首版明确不做

- 不实现异步 Rime filter 或修改 Squirrel/Weasel。
- 不把 bounded early heuristic 宣称为隐藏 beam 的完整安全证明。
- 不训练或微调模型。
- 不收集用户输入。
- 不自动发现 Ollama/oMLX。
- 不把 GGUF 提交到 git。
- 不顺带处理自学习、调频等其他债务。

## 8. 执行顺序

~~~text
Task 1 -> Task 2 -> Task 3 -> Task 4 -> Gate A/B
                                      |
                                      +-- FAIL: 记录并停止
                                      |
                                      +-- PASS -> Task 5 -> Task 6 -> Task 7
                                                             |
                                                             -> Task 8 -> Gate C
                                                                          |
                                                                          +-- FAIL: 不做异步 filter
                                                                          |
                                                                          +-- PASS -> Task 9 -> Gate D
                                                                                               |
                                                                                               -> Task 10
~~~

每个 Task 独立提交。Gate 失败必须形成可复现报告，不得以“后续优化”为由跳过。
