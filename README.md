# 虎码·整句（rime-tiger-sentence）

虎码连续整句输入方案：连续虎码经原生引擎（libtigerengine + V5 字符 n-gram
模型）出整句候选，确定性提前上屏稳定前缀，空格提交、回车上原码。基于魔虎
（[rime-mohu](https://github.com/fcxxxz/rime-mohu)）框架的整句能力独立成仓，
与魔虎双拼方案共用 `mohu/` 运行时（引擎、模型、学习层），可平行安装。

- 整句（`sentence` 开关，默认开）：字母连打整句候选；引擎不可用时自动退化为纯单字模式
- 提前上屏（`early_commit` 开关，默认开）：置信度门槛下自动提交稳定前缀
- 单字模式（Ctrl+T / 输入法菜单切「单字」）：4 码顶功 + 唯一候选自动上屏，与上游手感一致
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
（虎爪整句的 Rime 移植）的同码配对基准（2026-11-10，10,000 句 / 297,366 键，
三方逐句配对，训练重叠口径）：

| 指标 | 本方案 | tiger-sentense-rime 发布包 | 虎整原版 |
|---|---:|---:|---:|
| 最终首选准确率 | **99.83%** | 98.12% | 98.12% |
| 错误提前上屏率 | **0.050%** | 0.100% | 0.170% |
| 自动上屏字符覆盖率 | **88.3%** | 59.8% | 59.4% |
| 逐键处理器 CPU 均值 | **1.87ms** | 5.49ms | 8.34ms |
| 逐键处理器 CPU P99 | **14.7ms** | 19.9ms | 26.7ms |

配对差异：最终首选仅本方案正确 174 句 vs 仅 tiger-sentense-rime 正确 3 句。
注：tiger-sentense-rime HEAD 的五阶模型未随 Release 公开，对照采用其最新可
安装发布包；完整口径与限制见
[bench/reports/2026-11-10-lvyww-10k/report.md](bench/reports/2026-11-10-lvyww-10k/report.md)。
基准为训练重叠口径的离线逐键测评，不代表独立留出泛化；复现脚本在
[bench/lvyww-100k/](bench/lvyww-100k/)。

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
