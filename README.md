# 虎码·整句（rime-tiger-sentence）

[![Package release zip](https://github.com/fcxxxz/rime-tiger-sentense/actions/workflows/package.yml/badge.svg)](https://github.com/fcxxxz/rime-tiger-sentense/actions/workflows/package.yml)

虎码连续整句输入方案：连续虎码经原生引擎（libtigerengine + V5 字符 n-gram
模型）出整句候选，确定性提前上屏稳定前缀，空格提交、回车上原码。基于魔虎
（[rime-mohu](https://github.com/fcxxxz/rime-mohu)）框架的整句能力独立成仓，
与魔虎双拼方案共用 `mohu/` 运行时（引擎、模型、学习层），可平行安装。

- 整句（`sentence` 开关，默认开）：字母连打整句候选；引擎不可用时自动退化为纯单字模式
- 提前上屏（`early_commit` 开关，默认开）：置信度门槛下自动提交稳定前缀
- 单字模式（Ctrl+T / 输入法菜单切「单字」）：4 码顶功 + 唯一候选自动上屏，与上游手感一致
- 组句规则（虎整口径）：一简字 2 码占首选位；高频字组句只用最优码（h 过滤）；
  码长 ≥3 的非首选单字可省选重键参与组句（孑@rfi）；**γ 码形先验**（默认 6，
  组句边用非最优码形受罚、全码单打豁免）——短码组合优先，并字长码形
  （拟@uvjr 偷 指(uv)+人(jr) 类）不再反超；同码整段单字按码表档位序（蛰@ukic）
- 31 个二码位（qk/ck/ce…）首选单字（qk=眸）、简码词退次选（虎码秃版口径回插）
- 用户词套件沿用魔虎：`编码// + 空格` 加词、Shift+Delete 两段式删词（含引擎反学习）、
  Ctrl+方向键调序置顶、`==` 候选管理器
- `` ` `` 反查（Ctrl+R 循环 自然码双拼 → 小鹤双拼 → 全拼）；Ctrl+X 常用字/全字集

## 安装

1. 下载 `tiger-sentence-latest.zip`，解压全部内容到 Rime 用户目录
   （macOS：`~/Library/Rime/`；Windows：`%APPDATA%\Rime\`）
2. 从 Release 下载模型 `mohu-sentence-ngram-v5.bin`，放入 `~/Library/Rime/mohu/model/`
   （包内已预建该目录；没有模型时方案自动回退单字/词组候选，不报错）
3. 重新部署；macOS（Squirrel）更新运行时文件后须**完全退出并重启**——动态库按宿主
   进程生命周期加载
4. 切换到「虎码·整句」

与魔虎双拼方案共存：两者共用 `mohu/runtime/libtigerengine.dylib`、`mohu/model/`
与 `mohu/data/`，学习层（`mohu/config/user-ngram.snapshot`）互通；升级任一方时
同步更新 `mohu/runtime/` 下的引擎即可。

## 基准

对照 [lvyww/tiger-sentense-rime](https://github.com/lvyww/tiger-sentense-rime)
官方发布包（20260915）的同码流双臂打字模拟——**100,000 句终测（2026-11-12，
含 γ=6 引擎，seed 20261111，训练重叠口径）**：

| 指标 | 本方案 | 官方虎整 | 差值 |
|---|---:|---:|---:|
| 句末首选准确率 | **99.80%** | 98.10% | **+1.70pp** |
| 自动上屏字符覆盖率 | **88.20%** | 59.94% | +28.26pp |
| 句尾残留（打完瞬间） | **1.49 字** | 5.04 字 | −3.55 |
| 每键 CPU 均值 / P99 | **2.09 / 15.3ms** | 7.06 / 21.9ms | 3.4× / −30% |
| 错误提前上屏事件 | **156** | 359 | −57% |
| 安装包 | **6.8 MB** | — | — |

成绩单（总分/已落地/负结果归档/病例档案）见
[bench/scorecard-20261112.md](bench/scorecard-20261112.md)；完整证据链
（γ 标定、词表/重排/门槛三类负结果、错判病理）见
[bench/hz-lvyww-10k/report.md](bench/hz-lvyww-10k/report.md)。
注：官方 Release 未含其 HEAD 五阶模型；基准为训练重叠口径的离线逐键
测评，不代表独立留出泛化。双臂管线在 [bench/hz-lvyww-50k/](bench/hz-lvyww-50k/)
（50k 口径可复现，100k 终测同法扩样）。

## 码表（虎整码表）

整句层词表采用虎整码表（源自 [lvyww/tiger-sentense-rime](https://github.com/lvyww/tiger-sentense-rime)
的 `tiger_sentence.codes.txt`，GPL-3，已随仓库存放于
`tiger_sentence_native/data/tiger/hz-codes.txt`，由 `build_hz_lexicon.py` 生成引擎词表）。
其设计：**一简字 2 码占首选位**（的=ue、在=ng、要=vb、到=yp、我=tu、说=sh、和=xd、
是=ot；根字 不=cb、了=rl、人=jr、大=md、一=fi…），**同码原主人退长码**（皇=un 不受扰、
近=tuc、办=shb、存=ngh、集=uem）。组句解码定顶（`all_ranks=false`）即可，2 码打法
天然成立、无同码竞争：

| 配置（10,000 句配对） | 最终首选准确率 | 键数 |
|---|---:|---:|
| 用户自编虎单码表（原表基准） | 99.38% | 278,985 |
| 本方案（虎整码表+定顶） | **99.45%** | **266,471（−4.49%）** |

完整对照（含碰撞压力语料、一简字打法消融）见
[bench/usertable-10k/report-hz.md](bench/usertable-10k/report-hz.md)。
在虎整码表基础上的本地补丁（源头均改 `hz-codes.txt`，两条生成链同源同序）：
31 个二码位回插秃版单字（qk=眸 首选、简码词睡觉退次选）；词表第 7 列
flags（h=高频非最优码形硬过滤、o=全字非最优码形供 γ 罚分标记）。

## 开发

```sh
make test          # 全部 Lua 单测 + C++ 引擎测试（需 macOS 工具链重编 dylib）
make tigerengine-native   # 重编 libtigerengine.dylib
python3 make_dist.py      # 构建安装包 zip
```

- 引擎源码：`tiger_sentence_native/`（构建与模型格式见其 README）
- 提前上屏处理器：`lua/tiger_mode_proc.lua`（tracker + 静态复核）
- 资产来源与魔虎仓关系见 [PROVENANCE.md](PROVENANCE.md)（魔虎仓对本仓只读）

## 授权

GPL v3，见 [LICENSE](LICENSE)。V5 模型语料含 CC-BY-NC-SA 成分，模型文件仅限
个人/研究使用，随 Release 单独分发。
