# 本次提前上屏静态复核的性能分析（2026-10-26）

只读分析及临时插桩，没有修改生产代码。比较A=/tmp/tiger-100k-20261026-a3D7SM/new，B=/tmp/tiger-100k-rerun-20261026-r7ojxj5e/new。完整十万句处理器CPU均值0.905→3.661ms，P99 5.817→29.728ms。

## 实测

用同一驱动对前500句（14474键）插桩，两轮全部非时间R字段与原始全量记录逐句相同，插桩未改变上屏行为。时间是包含嵌套的累计CPU时间，不能把各行直接相加。

| 累计耗时 | A | B |
|---|---:|---:|
| 处理器 | 13.978秒 | 53.546秒 |
| 普通解码，含Lua解析 | 13.367秒 | 12.901秒 |
| 普通native调用，含桥接与序列化 | 9.087秒 | 8.707秒 |
| 新增静态解码，含Lua解析 | 无 | 39.880秒，5470次 |
| 静态native调用，含桥接与序列化 | 无 | 12.112秒 |

静态复核约占B处理器CPU的74.5%。其native调用之外的Lua解析/校验部分约27.768秒，占静态复核的69.6%。这个比例来自500句定位样本，不是对完整十万句逐函数采样。

另跑同口径100句测返回体积：普通native 2575次，10180676字节/57893行，平均22.48行；静态native 1037次，65781786字节/283640行，平均273.52行，单次最大217124字节。进一步插桩parse_output累计5745.280ms（普通+静态共3611次），重复文本校验87.976ms。解析是明确热点，但未将静态parse_output独立拆分。

## 原因

lua/tiger_mode_proc.lua:317起，每个truncated代都调用decode_static_with_early，即使user_model=false也执行。truncated也包含显示行数超过20，不只表示搜索束裁剪。

native decode_static保存live workspace，使用临时空workspace做全串decode_full/rebuild，完成后恢复live；live缓存没有被永久清除，但静态轮次既不复用live概率缓存，也不保留自己的概率缓存和搜索状态。模型底层context FIFO仍共享。

静态结果输出完整保留束（不是无限搜索），随后在Lua parse_output中对每条文本/preedit做UTF-8验证，解析数字、pathmap并创建表。decode拆items/early时逐条table.remove还会搬移数组。大量静态行只用于计算前缀证据，并非显示菜单。

## 优化优先级

1. 优先新增紧凑的静态证据接口。短期直接返回Lua结构，省文本格式化/正则解析并只携带text/confidence/raw边界等必要字段；收益仍需测量，因为仍会分配表。较完整方案在native按当前完整证据池计算前缀质量和边界质量，仅返回达标前缀、边界、share/strong标记。保留同文质量合并、已提交前缀过滤、visible-top门控、累加次序与失败保守语义。
2. 为静态复核保留独立概率缓存和workspace。先做相同raw的结果复用和概率缓存，失效键覆盖上下文、词表、模型/配置代次。仅保留workspace但继续decode_full不能省掉全串搜索；增量搜索另需证明等价。
3. 对native可证明完全无个人影响的句图，复用普通搜索裁剪前的完整静态视图，避免第二次搜索。user_model=false本身不足以证明没有个人词覆盖；现有top20输出不能代替完整证据；普通增量与静态全量搜索的路径集合也必须验证等价。
4. Lua侧以线性拆分替代循环table.remove；合并重复前缀计算，减少临时表与UTF-8重复扫描。这些属于次级优化，不能据此承诺回到旧版耗时。

不应通过缩beam、只看top20或可见行无learning_affected就跳过静态复核来提速，否则改变刚修好的判定。可优先保证候选、逐键提交文本及边界、错误集合与B一致，再用小样本定位和完整十万句验证速度收益。

当前仓库Lua两文件与B相同，native仍保留上述重复搜索和临时缓存路径；tigerengine.cc的incomplete_code_tail已出现额外语义改动。因此后续实施需要冻结新的基线，不能假定当前仓库完全等于本次测评B。

原始插桩脚本与结果在/tmp/tiger-performance-profile-20261026.lua、/tmp/tiger-profile-before-20261026.tsv、/tmp/tiger-profile-after-20261026.tsv、/tmp/tiger-profile-after-volume-20261026.tsv、/tmp/tiger-profile-parser-20261026.tsv。
