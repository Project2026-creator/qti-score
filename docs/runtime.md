# 试卷运行、响应处理与标准结果

QTI Score 0.25.0 可从 QTI 3 内容包编译试卷，运行分部分的作答会话，执行题目与试卷评分规则，并导出 QTI Result Reporting XML。MoonBit 核心承担编译、状态变更、评分和序列化；浏览器、命令行和 JavaScript SDK 共用这些逻辑。

## 运行示例

```sh
python tools/project.py build-web
moon run cmd/main -- test-describe web/runtime-test-package.zip runtime-test
moon run cmd/main -- test-run web/runtime-test-package.zip runtime-test examples/runtime-actions.json
moon run cmd/main -- test-run web/feedback-test-package.zip feedback-workflow examples/feedback-actions.json
moon run cmd/main -- test-run web/graphic-test-package.zip graphic-test examples/graphic-actions.json
python tools/project.py serve
```

在本机打开 [试卷运行器](http://127.0.0.1:4173/web/test.html)，可载入示例或自己的 ZIP，选择试卷资源、作答、保存、提交、暂停、恢复快照并导出结果。原有 [题目工作台](http://127.0.0.1:4173/web/) 保留单题编辑与批量分析功能。

基础示例分别展示下列流程；另有八题原生控件示例与 [组卷加权示例](assembly.md)。

| 内容包 | 流程 | 固定作答的预期结果 |
|---|---|---|
| `runtime-test-package.zip` | 非线性逐题提交，再线性整部分提交；同一题目文件被两个 ItemRef 独立引用 | 逐题 1、2、0、1，试卷总分 4 |
| `feedback-test-package.zip` | 跨响应运算、规则评分长文本、人工评阅长文本与作者反馈 | 逐题 5、2、NULL；人工待评，试卷总分 NULL |
| `graphic-test-package.zip` | 图形热点选择与活动区域匹配 | 逐题 1、3，试卷总分 4 |

这些作答文件使用固定的演示标识符与时间戳。运行器中的真实作答采用当前会话时间。

## 试卷结构与会话

支持 `qti-assessment-test`、多个 `qti-test-part`、嵌套 `qti-assessment-section`、包内 `qti-assessment-section-ref` 和 `qti-assessment-item-ref`。引用按分节的选择和编序规则展开，最多 4096 个候选引用与 512 个作答位置；同一题目文件的多个引用共享编译对象，各自保留响应、尝试次数和时长。清单依赖、相对路径和 `xml:base` 参与资源解析，未知引用、重复标识符、循环与越过包根目录的路径会报错。

| 能力 | 行为 |
|---|---|
| `navigation-mode="linear"` | 依次前往下一题，不允许任意选择题目 |
| `navigation-mode="nonlinear"` | 在当前部分内选择题目；仍执行跳题与复核限制 |
| `submission-mode="individual"` | `save` 校验并保存，`submit` 执行评分；修改后须重新提交 |
| `submission-mode="simultaneous"` | 部分内保存草稿，`finish_part` 一次评分；不提前公开分数 |
| `max-attempts` | 限制有效提交次数；0 表示不限，重复提交未修改的响应不增加次数 |
| `allow-skipping` / `allow-review` | 控制离开未答题目，以及最后一次尝试结束后的复核；剩余尝试不受复核禁用影响 |
| `show-feedback` | 控制会话中分数和作者反馈的显示，缺省 false |
| `qti-time-limits max-time` | 当前部分的秒数限制；宿主以 `tick` 检查并结束到时部分 |
| 暂停与恢复 | 暂停期间不计入时长，恢复时钟必须单调递增 |

有效控制值按试卷部分、分节、题目引用继承。所有响应在保存时校验，`validate-responses=false` 也不会允许类型错误或未知选项进入评分。逐题提交部分结束前需提交已修改的草稿。到时的未答必答题保留未完成处理状态与空分值，不生成零分。

固定顺序、分节抽题与编序已经实现，规则与种子接入见 [组卷指南](assembly.md)。条件导航支持范围和实际示例见 [前置条件与分支](navigation.md)。自适应题、测试整体与单题时间约束尚未实现，对相应结构返回 `unsupported`。宿主负责身份信息、持久存储和时钟来源。

QTI 标识符采用最多 256 个字符的 ASCII NCName 子集；外部分节展开后的标识符也受此限制，与结果 XML 导出的约束一致。普通资源路径和清单资源标识符使用各自的题包限制。

## SDK 接入

```js
import { importPackage } from '@project2026-creator/qti-score';

const bundle = importPackage(zipBytes);
const test = bundle.getTest('runtime-test');
const session = test.startSession('learner-session', { now: 0 });
try {
  session.act({ type: 'save', time: 1, response: { RESPONSE: 'A' } });
  session.act({ type: 'submit', time: 2 });
  console.log(session.describe());
  const snapshot = session.snapshot();
  const restored = test.restoreSession(snapshot);
  try { console.log(restored.describe()); }
  finally { restored.dispose(); }
  // 完成全部部分后：
  // const { report, xml } = session.exportResult(new Date().toISOString(), {
  //   candidateIdentifier: 'learner-id'
  // });
} finally {
  session.dispose();
  test.dispose();
  bundle.dispose();
}
```

同一模块最多保留 16 个活动试卷和 16 个活动会话。试卷与会话独立持有编译内容，题包或试卷释放后，已有会话仍可运行。图片资源需要在题包仍有效时通过 `readFile` 读取。

v2 快照包含测试身份标识、组卷种子、会话标识、起始时钟与已接受的动作；v1 快照保留在原核心版本恢复。恢复时重新运行校验和评分，不采用快照中的外部得分；题目规则、控制或引用发生变化时拒绝恢复。快照用于相同核心版本与相同编译内容，包含作答正文，宿主决定保存位置。最多记录 10,000 次动作，总长度受 8 Mi UTF-16 码元的快照读取限制约束。

MoonBit 可用 `ContentPackage::compile_test`、`AssessmentTest::new_session` / `restore_session`、`TestSession::act_json` / `describe` / `snapshot` / `report` / `result_xml`。`AssessmentTest::run_actions_json` 是 CLI 使用的完整动作重放入口。

## 类型化表达式与反馈

`compile_assessment_item` 保留既有模板与专用数值规则的快速路径，并为更一般的规则编译 `ProcessedItem`。也可直接调用 `compile_processed_item` 或 `compile_processing_program`。新类型是 `AssessmentItem::Processed`；穷尽匹配该枚举的调用者需要增加分支。

处理程序根据声明检查表达式类型、基数、变量引用和赋值目标；每次执行从作者声明的默认值重新开始。支持 `single`、`multiple`、`ordered`，基类型包括 boolean、identifier、string、integer、float、directedPair、pair。交互绑定仍须符合其响应类型，布尔值可用于中间表达式和结果变量。

| 类别 | 已实现的 QTI 元素（省略 `qti-` 前缀） |
|---|---|
| 值与引用 | `base-value`、`null`、`variable`、`correct`、`default`、`map-response` |
| NULL 与逻辑 | `is-null`、`not`、`and`、`or` |
| 比较 | `match`、`equal`、`lt`、`lte`、`gt`、`gte`、`string-match` |
| 运算 | `sum`、`product`、`subtract`、`divide`、`integer-divide`、`integer-modulus`、`min`、`max`、`integer-to-float` |
| 容器 | `multiple`、`ordered`、`member`、`container-size`、`index` |
| 试卷汇总 | `test-variables`，按分节、类别、类型与权重收集题目变量；支持 ItemRef 变量引用及实例序号 |
| 控制 | `set-outcome-value`、response/outcome 的 if/else-if/else 条件、`exit-response`、`exit-test` |
| 阈值换算 | outcome 声明中的 `interpolation-table`，以及赋值规则 `lookup-outcome-value` |

条件只执行首个为真的分支，NULL 与 false 区分；计算保持 QTI NULL 传播规则并拒绝非有限结果、类型不匹配与超出执行限额的程序。题目逐次提交与部分集中提交都会重新执行试卷结果处理，计算成功后才提交状态；普通提交失败不改变作答状态。到时强制结束时的试卷处理失败记录在报告的 `test_processing_error`，结果保留 NULL。分节、类别、权重与 ItemRef 变量语义见 [组卷指南](assembly.md#题目变量权重与过滤)。record、模板生成、随机表达式、全部数学与统计运算符仍待补充，未识别的结构明确报错。

`qti-modal-feedback` 根据结果变量与 `show-hide` 选择反馈，支持打印变量与题目反馈的嵌套。题目正文支持 `qti-feedback-inline`、`qti-feedback-block`，以纯文本呈现；打印格式和会话行为见 [动态内容](dynamic-content.md)。`qti-test-feedback` 提供进行中、部分结束和整卷结束反馈，可打印已提交的结果；部分历史在结束时冻结。阈值换算见 [分数换算与测验反馈](outcomes.md)。普通元信息不返回正确答案、映射或处理规则；`explain` 是显式开发者接口。完整 HTML 反馈布局和模板反馈仍待实现。

## 长文本与图形交互

长文本支持 `qti-extended-text-interaction` 的 `single/string`、`plain` 与 `preformatted`。`expected-length`、`expected-lines` 是显示提示，不截断作答；`min-strings=1` 要求非空文字。规则可使用文本比较及其他已支持的表达式评分；`external-scored="human"` / `"externalMachine"` 的 SCORE 可保持 NULL，并导出 `pendingExternalScoring`。项目不执行自动作文评价，也没有人工评阅后台。

图形交互支持 `qti-hotspot-interaction` 的 single/multiple identifier 响应，以及 `qti-graphic-gap-match-interaction` 的 multiple directedPair 响应。可读取包内图片与 rect、circle、ellipse、poly 区域，校验选项、整体关联数量和每个端点的 match-min/max。图形匹配允许符合使用次数约束的重复关联；映射仍对唯一键计分。评分依据标识符，不推测鼠标坐标。

试卷运行器提供包内图片、热点区域与文字控件。图形资源元信息位于 `describe().graphic`，正确选项与映射不在其中。picture 多源选择、百分比坐标、default 区域、图形排序、任意 HTML5 / MathML 内容呈现与完整无障碍偏好适配尚未实现。富文本长答案 `format="xhtml"` 也仍不支持。

## 交互兼容范围

题目工作台继续提供选择、排序、普通匹配、文本选词、Hottext、Inline Choice、Text Entry 和 Slider 的专用控件。试卷运行器已提供选择、文本／数值输入、长文本、滑杆、热点、图形匹配、普通配对、Gap Match、Hottext、排序与原位下拉控件；响应 JSON 仍作为开发者编辑入口，输入同样交由 MoonBit 校验和评分。

| 交互 | 已实现的响应与核心约束 |
|---|---|
| Choice | single/multiple identifier；有效选项及数量限制 |
| Extended Text | single string；plain/preformatted、必填、作者规则或外部待评 |
| Gap Match | single/multiple directedPair；词项使用次数与空位占用 |
| Graphic Gap Match | multiple directedPair；图形区域、来源和目标次数、重复关联 |
| Hotspot | single/multiple identifier；区域标识符、数量与重复选择校验 |
| Hottext | single/multiple identifier；静态文段、片段选项与重复选择校验 |
| Inline Choice | single identifier；候选值、必填与文段位置 |
| Match | single/multiple directedPair；方向、整体数量与端点次数 |
| Associate | single/multiple pair；换端等价、整体与端点次数、match-group；[接入说明](associate.md) |
| Text Entry | single string/integer/float；词法、范围、模板与类型化规则 |
| Order / Slider | ordered identifier 的顺序比较；single integer/float 的范围与步长 |

这些行描述已经实现的交互子集；内容模型、可选属性、呈现、无障碍和认证要求还需要分别验证。

## QTI Result Reporting

会话完成后可导出 JSON 与标准结果 XML。XML 使用 `http://www.imsglobal.org/xsd/imsqti_result_v3p0` 命名空间，包含 context、testResult、每个 ItemRef 的 itemResult、响应变量、结果变量、numAttempts 和 duration。itemResult 的 identifier 使用题目引用标识符；重复引用同一题目仍是独立结果，sequenceIndex 从 1 开始。

```sh
moon run cmd/main -- result-xml report.json
```

`assessment_result_xml(report)` 也可序列化符合合同的报告。报告须带变量类型，数值响应转换为对应的 XML 数值，容器基数和 directedPair 方向保留。未完成评分的题目由外部评分声明标记为待评，整卷 `all_items_scored=false`；作者可将 SCORE 显式置为 NULL，缺省的数值 0 也不会被当作已完成的人工评分。试卷结果仍执行作者声明的处理规则，不抹掉默认值和独立结果；`test-variables` 按标准排除 NULL。反馈示例显式检查已评分的 SCORE 数量，尚有待评题时把试卷 SCORE 设为 NULL，同时保留 MAXSCORE=7。`has_errors=false` 不能代替全部评分完成的判断：人工待评是有效状态。

条件排除且从未呈现的题以 `initial` 导出，尝试次数与时长为 0，响应为 NULL，结果变量保留声明初值；这些题不执行响应处理，不参加已提交题目的汇总，也不计为人工待评。JSON 的 `presented` 与 `skipped` 区分已呈现题和规则排除题。

XML 针对 [QTI 3 Result Reporting Candidate Final Public](https://www.imsglobal.org/sites/default/files/spec/qti/v3/rr-bind/index.html) 及其 [Result XSD](https://purl.imsglobal.org/spec/qti/v3p0/schema/xsd/imsqti_resultv3p0_v1p0.xsd) 验证。该结果规范的发布状态与 [ASI 3.0.1 Final 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/imsqti_asi_v3p0p1_infomodel_v1p0.html) 分别记录，不把两者版本混称。旧有批量 JSON/CSV 用于逐行分析，与此结果交换格式分别提供。

## 独立验证

```sh
python -m pip install lxml==6.1.1
python tools/asi_schema_test.py --report _build/asi-schema-report.json
python tools/result_schema_test.py --report _build/result-schema-report.json
python tools/runtime_test.py --output _build/runtime-validation.json
```

首次运行 schema 工具会下载指定版本 XSD，并校验固定 SHA-256；后续可加 `--offline` 使用缓存。XML 解析关闭网络与外部实体。结果测试调用真实 CLI，再由 lxml 和独立结果读取逻辑检查输出；运行流程测试同时调用 CLI 与 SDK，比对手写预期的引用、分数、时长、快照与失败行为。常规核心测试使用 `moon test --target all`，原有跨入口检查仍通过 `python tools/project.py check` 运行。

XSD 验证覆盖示例的结构与结果文档，运行测试覆盖列出的行为；项目未完成全量 QTI 3、全部 Advanced 要求或 1EdTech 产品认证。
