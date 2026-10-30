# 按规则组卷与加权结果

0.21.0 在编译试卷时处理分节抽题和编序。宿主显式提供组卷种子，得到已经选定题目与顺序的 `AssessmentTest`；同一编译对象开启的会话使用这份组卷结果。需要重新抽取时，使用另一种子编译；不同种子也可能抽到相同的组合。

## 运行示例

```sh
python tools/project.py build-web
moon run cmd/main -- test-describe web/assembly-test-package.zip assembly-test --seed 0
moon run cmd/main -- test-run web/assembly-test-package.zip assembly-test examples/assembly-actions.json --seed 0
moon run cmd/main -- test-describe web/assembly-test-package.zip assembly-test --seed 42
```

示例从四个引用中选三个，保留必选题的位置，再运行同一 ItemRef 的两个独立实例。种子 0 选择 `anchor, evidence, measurement, repeat, repeat`，种子 42 选择 `anchor, measurement, review, repeat, repeat`。

种子 0 的固定作答得到逐题分数 `1, 2, 1, 0, 1`。作者设置前面三题的权重为 `2, 1.5, 0.5`，后两题默认权重 1，因此 SCORE 为 **6.5**；类别汇总 CORE 为 **3**，必选题加权结果 ANCHOR 为 **2**，第二个重复实例的结果 SECOND 为 **1**。全部结果由 XML 中的规则计算。

```js
const plan = bundle.getTest('assembly-test', { seed: 42 });
try {
  const metadata = plan.describe();
  console.log(metadata.assembly_seed, metadata.candidate_count);
  console.log(metadata.entries.map(entry => ({
    instance: entry.identifier,
    source: entry.source_identifier,
    occurrence: entry.instance_index
  })));
  const session = plan.startSession('candidate-session');
  try { console.log(session.describe()); }
  finally { session.dispose(); }
} finally { plan.dispose(); }
```

MoonBit 对应入口为 `compile_assessment_test(xml, items, seed~)` 与 `ContentPackage::compile_test(resource_id, seed~)`。种子为 0–2,147,483,647 的整数，缺省 0。CLI 的非法种子返回退出码 2，SDK 在分配句柄前拒绝非法值。

## 抽题与编序规则

| 结构 | 实现行为 |
|---|---|
| `qti-selection select` | 从当前分节的直接子项抽取，子节在这一层按一个单元计算 |
| `required="true"` | 保证该子项被选中；必选项数超过 select 时拒绝试卷 |
| `with-replacement="false"` | 无放回选择，数量不能超过可用子项 |
| `with-replacement="true"` | 先保证必选项，剩余不同子项被选过后再从全体克隆；每个子节克隆独立执行内部规则 |
| `qti-ordering shuffle="true"` | 完成抽取后乱序，`fixed="true"` 保留在已选序列中的位置 |
| `visible` / `keep-together` | 任一为 true 时子节整体参与父级乱序；两者均 false 时提升子节内容参与混排 |

未乱序的选择结果保留来源顺序，所有 TestPart 仍按文档顺序执行。使用固定的整数随机算法、拒绝采样和 Fisher–Yates 编序；各部分从根种子与部分标识符派生独立流。四个后端使用同一算法。

当前对固定且透明的子节进入乱序祖先这一组合明确返回 `unsupported`，即子节同时 `fixed=true`、`visible=false`、`keep-together=false` 时不推测其父级固定位置。自定义 selection/ordering 扩展及自适应交付仍未实现。前置条件和分支支持固定顺序的独立导航流程，具体边界见 [条件导航](navigation.md)；本版本不组合活动题目／分节条件与抽题或乱序。

最多编译 4096 个候选题目引用，组卷后最多 512 个作答实例。组卷树最多 8192 个来源节点、64 层、32768 个中间展开节点。所有候选内容都会先校验，未被选中不能隐藏无效引用或错误题目。

## 实例与保存恢复

`entries[].identifier` 是会话中唯一的运行实例标识符。`source_identifier` 保留原 ItemRef 标识符，`instance_index` 从 1 开始记录该来源的出现次数。重复实例各自保存响应、尝试次数、时长与得分，生成的运行标识符不会与作者声明的标识符冲突。

结果 JSON 同时提供 `identifier`（来源）、`instance_identifier`（运行实例）和 `instance_index`。标准 XML 的 itemResult.identifier 使用来源 ItemRef，sequenceIndex 使用本次组卷中的全局位置；同一来源可以对应不同的 sequenceIndex，运行实例标识符不写入标准 XML。

快照格式升级为 `qti-score-test-session-v2`，记录组卷种子并绑定整个候选内容、规则和选定顺序。恢复须使用相同内容、种子和核心版本，重新执行已接受的动作。0.20.0 的 v1 快照需要在原版本继续使用。

## 题目变量、权重与过滤

ItemRef 可声明 `category` 和多个 `qti-weight`。试卷编译将题目变量类型、来源、祖先分节和类别绑定到处理程序。

- `qti-variable identifier="Q01.SCORE"` 读取题目变量；`Q01.2.SCORE` 读取该来源的第二个实例，序号与整卷位置分别计算。
- 重复来源在 simultaneous 提交中未指明实例时，读取最后提交的实例；individual 重复来源的无实例引用结果为 NULL，作者可以明确指定实例。
- 响应变量只读取最后已提交的响应，草稿不进入结果处理。未抽中的已声明来源返回 NULL，未知变量在编译时诊断。
- `weight-identifier` 引用当前 ItemRef 的权重，未声明时默认 1.0。数值变量加权后是 float，非数值变量不应用权重。
- `qti-test-variables` 支持 `section-identifier`、`include-category`、`exclude-category` 和 `weight-identifier`。分节过滤包含其子节；include 匹配任一所列类别，exclude 排除匹配任一所列类别的题目。
- 显式 `base-type` 按声明类型筛选，不把 integer 误当作 float；省略时收集数值单值，按实际非 NULL 值的类型选择整数计算或提升为浮点。缺少变量、NULL 和非 single 变量不进入集合。

独立使用 `compile_processing_program` 时，可通过 `item_declarations~:Json` 提供静态变量类型：

```json
[{"identifier":"Q01","outcome_types":{"SCORE":{"base_type":"float","cardinality":"single"}},"response_types":{},"categories":["core"],"section_identifiers":["section1"]}]
```

运行输入仍是 `{"items":[...]}`，每项提供来源 identifier、outcomes，以及需要的 response、instance_index、submitted、submission_mode、submission_index 和 weights。`ContentPackage::compile_test` 与 `TestSession` 已完成这些绑定和输入构造。跨题 correct/default、variable-mapping、record 和内置时长变量尚未扩展。

实现依据：[ASI 3.0.1 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/imsqti_asi_v3p0p1_infomodel_v1p0.html)、[实施指南 §4.5](https://www.imsglobal.org/spec/qti/v3p0/impl/)、[结果报告 §2.4.5](https://www.imsglobal.org/sites/default/files/spec/qti/v3/rr-bind/index.html)。
