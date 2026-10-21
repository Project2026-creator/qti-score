# QTI Score

A MoonBit library for importing QTI 3 ZIP content packages and scoring a focused subset of items. Supports choice, ordering, directed matching, gap filling, text and numeric entry, batch result reports and CSV export, developer explanations, and an ESM JavaScript SDK backed by the same MoonBit core.

QTI Score 将 QTI 3 题目编译成可重复使用的评分对象。核心库负责 XML 命名空间、响应类型、标准答案、映射和数值比较；命令行、浏览器与 JS SDK 使用同一份实现。适用于测验平台接入、题目迁移验证和教育技术课程中的标准实验。

## 快速运行

需要 **MoonBit 0.10.16 或更新的兼容版本**。本项目在 `moonc v0.10.16+b1a0e846e` 上验证。浏览器构建脚本使用 Python 3.8+；完整入口对照检查还需要 Node.js。

在项目根目录运行：

```sh
moon update
moon test --target all
moon run cmd/main -- score examples/multiple.xml examples/multiple-response.json
```

该示例返回 `score: 2`、`status: "answered"`、`matches_correct: true`。

```sh
# 题目元信息
moon run cmd/main -- describe examples/single.xml

# 文本填空：大小写部分得分 0.5
moon run cmd/main -- score examples/text.xml examples/text-response.json

# 数值填空：100.5 在绝对误差范围内，得 1 分
moon run cmd/main -- score examples/numeric.xml examples/numeric-response.json

# 显式获取开发者评分解释
moon run cmd/main -- explain examples/numeric.xml examples/numeric-response.json

# 同一题目的多次作答，逐行输出 JSON
moon run cmd/main -- batch examples/multiple.xml examples/attempts.jsonl

# 构建并启动浏览器工作台
python tools/project.py serve
```

浏览器打开 [http://127.0.0.1:4173/web/](http://127.0.0.1:4173/web/)。可切换十个示例、编辑或导入 XML，并查看作答和评分结果。勾选“记录评分过程”后，提交作答会显示分支判断、映射贡献、顺序比较与分值限制。示例界面用纯文本呈现题干，不实现完整 QTI 内容渲染；`shuffle` 等呈现信息不改变评分计算，演示按原文顺序初始显示选项。

## 排序题

支持 `qti-order-interaction`，绑定 `ordered/identifier` 的 `RESPONSE`，通过 `match_correct` 逐位置比较。标准序列中每个位置均相同得 1 分，其余有效序列得 0 分；不按位置分别给部分分数。排序题不能使用 `map_response` 或本库的数值内联规则。图形排序、动态显示选项及其他 ordered 基类型仍不在支持范围内。

```sh
moon run cmd/main -- score examples/order.xml examples/order-response.json
moon run cmd/main -- explain examples/order.xml examples/order-response.json
```

JSON 仍使用字符串数组，数组顺序有意义：

```json
{"RESPONSE":["Analyze","Design","Develop","Implement","Evaluate"]}
```

类型化 API 使用 `Response::Ordered([...])`；`Response::Multiple` 保持多值语义，不能代替有序容器。`Item::score_json` / `explain_json` 根据题目基数解释数组。独立辅助函数 `response_from_json` 不知道题目上下文，仍将数组解析成 `Multiple`，保持原有调用兼容。JS SDK、题包与跨题批量输入自动使用相应题目的上下文。

按 [QTI 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/index.html) 的 OrderInteraction（5.97）：未指定 `min-choices` 时必须排列全部选项，`max-choices` 在语义上被忽略；该属性的数字词法仍会校验。显式最小值必须至少为 1，最大值缺省为选项总数；显式范围满足 `1 ≤ min ≤ max ≤ 选项数`。元信息返回生效的数量范围。非空响应按范围验证；`null`、省略 RESPONSE 或空数组表示未作答，得 0 分。未知选项、重复选项、空字符串成员、错误容器和不满足数量范围的非空响应会报错；标准响应也必须引用合法、不重复的选项并满足范围。

网页“排序题”提供上移／下移按钮和“采用当前顺序”；初始排列尚未作为作答，确认或调整后才记录答案，清空会恢复未作答。按钮可通过 Tab、Enter 或空格操作，移动后焦点留在对应项目。“选择并排序”示例可添加、移动和移除项目。排序解释的 `match_correct` 步骤增加 `comparison:"ordered"`，便于区分逐位置比较。

构建命令还会从仓库内源文件生成独立的排序题包，包含完整排序与子集排序题：

```sh
python tools/project.py build-web
moon run cmd/main -- inspect-package web/order-package.zip
moon run cmd/main -- package-batch web/order-package.zip examples/order-attempts.jsonl
```

可在网页导入 `web/order-package.zip`，再向批量工作台导入 `examples/order-attempts.jsonl`。该示例包含 4 条记录，3 条评分成功、1 条因重复选项失败，CLI 返回完整报告并退出 1。原有综合示例题包保持原样。

## 配对题

支持 `qti-match-interaction` 的 `single/directedPair` 和 `multiple/directedPair`，可使用 `match_correct` 或 `map_response`。两组 `qti-simple-match-set` 分别定义来源和目标；每个值写成 `"来源标识符 目标标识符"`，方向不可交换。多个配对的排列顺序不影响评分。标识符区分大小写；配对中的 XML 空白（空格、Tab、CR、LF）统一折叠为一个空格，其他分隔符不接受。

```sh
moon run cmd/main -- score examples/match.xml examples/match-response.json
moon run cmd/main -- explain examples/match.xml examples/match-response.json
```

```json
{"RESPONSE":["Quiz Diagnose","Portfolio Growth","Observation Diagnose"]}
```

原生类型化 API 沿用 `Response::Multiple(["Quiz Diagnose", ...])`，单组配对用 `Response::Single("Portfolio Growth")`；JSON/SDK 同样按题目基数接收数组或字符串。`match_correct` 完全匹配得 1 分；`map_response` 复用现有默认值、部分分数与上下界。示例中正确关联各得 1 分、错误关联扣 0.5 分，总分限制在 0–3。

按 [QTI 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/index.html) 的 MatchInteraction（5.89）和 SimpleAssociableChoice（5.131）：`max-associations` 缺省为 1，0 表示不限；`min-associations` 缺省为 0。`single` 必须使用最大值 1。每个选项的 `match-max` 必填、0 表示不限，`match-min` 缺省为 0。非空响应必须满足整体和各选项的次数限制；NULL、空字符串单值和空多值数组保持未作答，按模板得 0 分。重复关联、未知标识符、同组或反向配对均报错。编译时检查标准响应的有效性、映射键的端点与规范化后的重复键。

`describe()` 的 `base_type` 增加 `directedPair`。配对题额外返回 `matching`，包含 `min_associations`、`max_associations` 和两组 `sets`；各选项含标识符、纯文本及 `match_min`/`match_max`，不含正确配对。原有 `choices` 保持为空，`min_choices`/`max_choices` 对应整体关联范围。其他题目的元信息形状保持原样。公开枚举 `BaseType` 新增 `DirectedPair`，穷尽匹配的调用者需处理新增分支。

网页用原生下拉框和按钮添加/移除关联，可通过键盘操作；单组模式再次添加会替换原关联。初始不自动作答，修改后清除旧结果，次数与配对合法性在提交时由核心检查。演示按原文显示选项，不执行随机呈现。`match-group`、模板控制显示、无向关联及图形配对暂不支持，遇到相应结构明确报错。

```sh
python tools/project.py build-web
moon run cmd/main -- inspect-package web/match-package.zip
moon run cmd/main -- package-batch web/match-package.zip examples/match-attempts.jsonl
```

独立配对题包包含两个示例；批量示例有 4 行，成功分数为 3、0.5、未作答 0，另有一行因来源超出关联次数失败。报告继续保留错误行，CLI 退出 1。可在网页导入相同 ZIP 和 JSONL 直接验证。

## 选词填空

支持 `qti-gap-match-interaction` 的文本词库 `qti-gap-text` 与文段空位 `qti-gap`。响应仍是有向配对：词项标识符在前，空位标识符在后。多个空位使用 `multiple/directedPair` 数组；一个空位也可使用 `single/directedPair` 字符串。完全匹配和映射部分分数复用前述评分模板。

```sh
moon run cmd/main -- score examples/gap.xml examples/gap-response.json
moon run cmd/main -- explain examples/gap.xml examples/gap-response.json
python tools/project.py build-web
moon run cmd/main -- package-batch web/gap-package.zip examples/gap-attempts.jsonl
```

示例响应为 `{"RESPONSE":["Feedback G1","Adjust G2","Feedback G3"]}`，得 3 分。词项 `Feedback` 可使用两次；每个空位最多接收一个词。空位 `required="true"` 表示非空响应中必须填写该空；词项的 `match-min`/`match-max` 分别约束使用次数。整体 `min-associations` 默认 0，`max-associations` 默认 **1**，0 表示不限；多空题通常需要作者显式设置合适的最大值。一个文段包含多个空位时必须使用 multiple，single 的最大值必须为 1。NULL/空容器保留未作答的模板评分，交互中的必填约束不会隐式生成作答。未知/反向配对、重复关联、向同一空位填两个词、超出词语复用次数或漏填必填空位的非空响应均明确报错。

XML 编译保留文字、实体、CDATA、嵌套文字与空位的顺序。`describe().gap_matching` 包含与 `matching` 相同的 `sets` 和数量限制，并额外包含 `passage`：按文档顺序排列的 `{text:string}` 或 `{gap:string}`。第一组是可选词，第二组是空位，空位的 `match_min` 为 0 或 1，`match_max` 固定为 1；`text` 是作者的 label，缺省为空位 ID。元信息不含正确配对或映射条目。普通配对仍返回 `matching`，现有其他题型的元信息不变，原生响应类型和已有 SDK 方法无需改变。

网页在文段内使用可键盘操作的原生下拉框，并实时显示填词后的纯文本文段。清空恢复所有空位未作答；更改词语清除旧评分。演示保留常见纯文本段落、换行和文字嵌套顺序，不注入原始 HTML、不执行作者脚本或随机呈现。当前接受 p/div/blockquote/ul/ol/li 等文段和常见文字标签；图像词库、其他富媒体、match-group、模板控制显示及本段未列出的结构均不支持。依据见 [QTI 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/index.html) 的 Gap（5.55）、GapMatchInteraction（5.57）、GapText（5.58）。

独立题包 `web/gap-package.zip` 包含多空、单空两个示例。`examples/gap-attempts.jsonl` 包含 5 行，4 行成功（3、1、0.5、未作答 0 分）、1 行因词项使用过多失败，CLI 输出完整报告并退出 1。

## QTI ZIP 题包

浏览器点击“载入示例题包”或“导入 ZIP”，可查看逐题兼容状态、清单资源与共享依赖，选取可评分题目后直接作答。示例包含单选、数值填空以及一份暂不支持的长文本题；长文本题的错误不会阻止前两题评分。演示仅读取本地内容，资源文件不自动执行或注入 HTML。

```sh
# 从 examples 中的源文件生成确定性的示例 ZIP，并构建网页与 SDK
python tools/project.py build-web
moon run cmd/main -- inspect-package web/sample-package.zip
moon run cmd/main -- package-score web/sample-package.zip choice examples/single-response.json
moon run cmd/main -- package-explain web/sample-package.zip measurement examples/numeric-response.json
```

MoonBit 宿主读取 ZIP 字节后调用：

```moonbit
let bundle = @qti.read_content_package(zip_bytes)
println(bundle.describe())
let item = bundle.item("choice") // 清单 resource identifier，而非题目 identifier
println(item.score(@qti.Response::Single("A")))
let paths = bundle.resource_files("choice") // 含传递依赖，去重
let data = bundle.read_file("assets/note.txt") // 精确、区分大小写的 ZIP 路径
```

`describe()` 返回文件列表、资源类型、依赖、资源诊断，以及每道题的 `ready` / `unsupported` / `invalid` 状态。单题失败保留其错误和可定位的 XML 行列；`item(resource_id)` 重抛该错误。报告不包含正确答案、映射规则或文件内容。文件缺失与循环依赖会影响其依赖者，独立题目仍可导入；清单格式、危险路径、重复 ZIP 成员和 ZIP 损坏导致整体失败。

支持根目录 `imsmanifest.xml`，QTI 3 CP 命名空间 `http://www.imsglobal.org/xsd/qti/qtiv3p0/imscp_v1p1` 及通用 CP 命名空间 `http://www.imsglobal.org/xsd/imscp_v1p1`。自动编译 `imsqti_item_xmlv3p0` 资源；其他资源保留为文件与依赖元信息。`href` 按清单及继承的 `xml:base` 解析，UTF-8 百分号解码一次；ZIP 成员名保持原文。支持包内相对路径，拒绝外部 URL、查询、片段、编码分隔符和越过包根目录的路径。入口 `href` 必须包含在所属资源的 `file` 列表中。

默认限额：**8 MiB ZIP、512 个条目、每文件 4 MiB、解压总量 16 MiB**；CRC 全量检查，所有内容只保存在内存中。MoonBit 可通过 `PackageLimits` 调整至最多 64 MiB / 4096 条目 / 16 MiB 每文件 / 128 MiB 总量。清单另限 512 个资源、4096 个资源子引用，每个资源最多报告 8 条诊断；所有 XML 仍受下文的独立限制。多资源引用同一题目文件时复用编译结果。

此功能是题包读取与评分接入子集：metadata、organizations 保留在原始清单中但不执行，未实现完整 CP/XSD 校验、试卷编序或资源渲染。0.3.0 新增 `QtiError::InvalidPackage`；穷尽匹配该错误枚举的调用者需处理新增分支。

## 跨题批量评分与导出

导入题包后，可以一次评分多个作答 ID、多个题目的 JSONL 记录。每个非空行包含 `attempt_id`、清单 `resource_id` 和 `response` 对象：

```json
{"attempt_id":"class-01","resource_id":"choice","response":{"RESPONSE":"A"}}
{"attempt_id":"class-01","resource_id":"measurement","response":{"RESPONSE":100.5}}
```

`attempt_id` 标识一次测验作答；同一 ID 可跨题共享。`response: {}` 或 `{"RESPONSE":null}` 表示未作答，整个 `response` 字段仍须存在且为对象。同一批次中相同 `(attempt_id, resource_id)` 的**所有行均报错**，不会自动挑选其中一次；修正冲突后重新评分即可。重复检测也包括身份有效但响应形状错误的行。

```sh
python tools/project.py build-web
moon run cmd/main -- package-batch web/sample-package.zip examples/package-attempts.jsonl
moon run cmd/main -- package-batch web/sample-package.zip examples/package-attempts.jsonl --csv
```

示例实际预期为 6 条记录、4 条评分成功、2 条错误，其中 1 条合法未作答。错误行的 `result` 为 `null`，错误不按零分处理。报告保留原始行号、资源 ID、可用的题目 ID、评分结果与结构化错误；按作答 ID 另列成功／失败／已答／未答数量和成功行分数和。字段 `all_rows_scored` 仅表示所提交行全部评分成功。未提交的题目不补零，不据此推断试卷总分、满分、权重或完成状态。

```moonbit
let report = bundle.score_attempts_jsonl(jsonl_text)
println(report.to_json())
let csv = report.to_csv()
let rows = report.rows() // 独立数组，保留输入顺序
let attempts = report.attempts() // 按作答 ID 首次出现的顺序
```

```js
const { report, csv } = bundle.scoreAttempts(jsonlText);
console.log(report.rows, report.attempts);
// 两种格式来自同一次 MoonBit 评分，无需另行解析或评分。
```

浏览器展开“题包批量评分与结果导出”，载入示例或 UTF-8 JSONL 文件，查看逐行结果并下载 JSON／CSV。修改输入或更换题包会清除旧结果并禁用导出，重新评分后恢复。导出不附带原始响应对象、正确答案或评分解释；错误消息仍可能描述无效的输入值。

输入限制为 **4,194,304 UTF-16 码元、4096 条非空记录**；每行最多 1,048,576 码元、JSON 深度 16。前两项超限导致整体失败，单行格式或评分错误保留在该行，继续处理后续记录。允许空行、CRLF 和文件开头的一个 BOM；拒绝重复 JSON 成员及未知外层字段。`attempt_id` 长度 1–256、`resource_id` 长度 1–4096，均不允许首尾空白或控制字符，不会裁剪或合并不同 ID。无法验证作答 ID 的行计入 `unassigned_count`。

成功行使用原始 Double 分数按输入顺序相加，可包含负分和作者为 NULL 设置的非零分。无成功行时 `score_sum` 为 `null`；求和首次出现非有限数时也为 `null`，并通过 `sum_error` 报错，原始逐题分数仍保留。`has_errors` 包含行错误与汇总错误。CLI 在这些情况下输出完整报告并退出 1；整体成功退出 0，参数错误退出 2。JSON 模式的 `ok:true` 表示批次已完成处理，需同时检查报告和退出码；整体不可处理时仍输出常规 JSON 错误，包括请求 CSV 时。

CSV 固定 12 列，错误行得分留空；按 [RFC 4180](https://www.rfc-editor.org/rfc/rfc4180) 处理逗号、双引号和 CRLF。文本字段以 `= + - @` 及其全角形式开头（含空白后），或以制表／换行开头时添加单引号前缀，以减少表格公式解释风险；数字得分不改变，JSON 保持原始 ID。此转换不保证各表格应用保存后仍保留前缀，需要精确交换数据时使用 JSON。核心 CSV 不带 BOM，网页下载添加 UTF-8 BOM，便于显示中文。导出处理依据见 [OWASP CSV Injection](https://owasp.org/www-community/attacks/CSV_Injection)。

`tools/project.py` 优先使用 `--moon PATH` 或 `QTI_MOON` 指定的工具链，其次使用存在的 `_build/toolchain/bin/moon`，最后使用 PATH 中的 `moon`。它不会安装软件或修改系统工具链。首次准备环境请参见 [MoonBit 官方下载说明](https://www.moonbitlang.com/download/)；旧版工具链可能无法编译当前依赖使用的 `Int32` 类型。

## 作为库使用

模块标识为 `Project2026-creator/qti-score`，源码见 [GitHub 仓库](https://github.com/Project2026-creator/qti-score)。当前尚未发布到 Mooncakes；工作区或发布后的消费者可使用以下包导入：

```moonbit
import {
  "Project2026-creator/qti-score" @qti,
}
```

```moonbit
// xml_text 由宿主读取；核心库本身不读文件、不发网络请求。
let item = @qti.compile_item(xml_text)
let result = item.score(@qti.Response::Multiple(["A", "C"]))
println(result.score)

// 已编译题目可用于多次作答，不必重复解析 XML。
let next = item.score_json("{\"RESPONSE\":[\"A\"]}")
```

上述调用会抛出 `QtiError`，调用者应声明 `raise` 或处理异常。公开类型和签名见 [pkg.generated.mbti](pkg.generated.mbti)。

主要接口：

| 接口 | 用途 |
|---|---|
| `compile_item(xml, limits?)` | 编译题目并检查本库支持的语义边界 |
| `Item::score(Response)` | 对类型化响应评分 |
| `Item::score_json(text)` | 对 JSON 响应评分，复用题目 |
| `Item::explain(Response)` / `Item::explain_json(text)` | 同一执行路径上的评分结果与开发者解释 |
| `Item::describe()` | 返回题目、交互和选项的纯文本元信息 |
| `evaluate_json(xml, response_json)` | 不抛异常的 JSON 宿主边界 |
| `describe_json(xml)` | 不提交作答，编译并返回 JSON 元信息 |
| `explain_json(xml, response_json)` | 显式返回结果与步骤的 JSON 宿主边界 |
| `read_content_package(bytes, limits?)` | 在内存中导入有大小限制的 ZIP 题包 |
| `ContentPackage::item(resource_id)` | 获取已编译的可评分题目 |
| `ContentPackage::describe()` / `resource_files(id)` / `read_file(path)` | 兼容报告、传递依赖文件和原始字节 |
| `ContentPackage::score_attempts_jsonl(text)` | 跨题批量评分、重复检测与作答汇总 |
| `BatchReport::to_json()` / `to_csv()` / `rows()` / `attempts()` | 导出报告和独立结果数组 |

响应 JSON 为单个对象：

```json
{"RESPONSE":["A","C"]}
```

标识符和文本单值用字符串，多值与有序响应均用字符串数组，排序题保留数组顺序；数值题还接受有限 JSON 数字，例如 `{"RESPONSE":100.5}`。`null` 或省略 `RESPONSE` 表示未作答。未知成员、重复键、布尔响应会被拒绝；非数值题不能接收数字。单基数响应不能用单元素数组代替。类型化 API 对数值响应提供 `Response::Number(Double)`，也接受数值文本。

评分对象包含：

```json
{"score":2,"status":"answered","matches_correct":true}
```

`matches_correct` 表示与作者声明的标准响应完全匹配，与映射得分分别计算。未声明标准响应时为 `null`。部分得分、同分替代答案都不自动等于“完全匹配”。

数值题中该字段表示与标准值的精确数值相等；进入容差范围可获得分数，而 `matches_correct` 仍为 `false`。普通评分不返回解释；显式解释可能揭示评分规则，适合开发者诊断。每个步骤包含操作名、XML 源位置和结构化详情。

## JavaScript SDK

```sh
python tools/project.py build-sdk
node examples/use-sdk.mjs
```

独立 ESM 包生成到 `_build/sdk/qti-score/`，包括编译后的 MoonBit 核心、TypeScript 声明和许可文件，无运行时依赖。可以复制该目录，或用 `npm install /absolute/path/to/_build/sdk/qti-score` 接入自己的应用。SDK 尚未发布到 npm，包当前标记为 private。

```js
import { compileItem } from '@project2026-creator/qti-score';

const item = compileItem(xmlText);
try {
  console.log(item.score({ RESPONSE: 100.5 }));
  console.log(item.explain({ RESPONSE: 100.5 }));
  console.log(item.scoreBatch([{ RESPONSE: 100 }, { RESPONSE: 'bad' }, {}]));
} finally {
  item.dispose();
}
```

`compileItem` 编译一次，之后复用评分对象；`describe()` 每次返回独立元信息。单个模块最多保留 256 个活动编译对象，使用结束调用 `dispose()`；重复释放安全，释放后调用抛出 `disposed` 错误。`scoreBatch` 最多处理 4096 次作答，逐条返回成功或错误，错误不会中断后续行，索引从 0 开始。另有 `evaluateItem`、`describeItem` 一次性接口。浏览器工作台也通过 SDK 使用编译对象。完整接口与边界见 [SDK 文档](sdk/README.md)。

`importPackage(Uint8Array)` 导入题包，返回 `describe`、`getItem`、`resourceFiles`、`readFile`、`dispose`。每个模块最多保留 4 个活动题包；`getItem` 使用上述 256 个编译对象配额。打开的题目独立释放，题包释放后仍可评分。导入输入和返回的字节、报告均与内部状态隔离。可运行 [题包 SDK 示例](examples/use-package.mjs)：`node examples/use-package.mjs`。

## 支持边界与评分语义

- QTI 3 命名空间必须是 `http://www.imsglobal.org/xsd/imsqtiasi_v3p0`；支持默认命名空间、前缀与 XHTML 题干元素。
- 每道题一个 `RESPONSE`，一个 `single/float` 类型的 `SCORE`，以及一个选择、排序、配对、选词填空或文本填空交互。标识符采用 ASCII NCName 子集；题干与文本答案支持 Unicode。
- 单选／多选使用 `identifier` 类型；文本填空使用 `single/string`。支持正确答案、映射、分值上下界和可选的初始 SCORE 值。
- 识别 `purl.imsglobal.org/spec/qti/v3p0/rptemplates/` 和官方示例中旧的 `www.imsglobal.org/question/qti_v3p0/rptemplates/` 地址；两者均接受 HTTP／HTTPS 和可选 `.xml` 后缀。匹配完整 URI，不根据文件名猜测模板，不下载模板。
- `match_correct` 在完全匹配时固定赋值 **1**，其他情况赋值 **0**。`normal-maximum` 是元信息，不缩放该模板的分数。
- 多值完全匹配采用无序多重集比较，保留重复次数；`map_response` 对每个不同输入值只计一次，再对总和应用上下界。
- 映射中的未知有效选项使用 `default-value`，省略时默认 **0**。文本映射按文档顺序取第一个匹配项，`case-sensitive` 默认 `false`，使用 Unicode case folding；标识符始终区分大小写。建议把具体的大小写敏感条目放在较宽泛的条目前。同名键及重复的不区分大小写键被拒绝。
- 单值空字符串、空多值／有序容器与 `Null` 按 QTI NULL 处理。两种模板的 NULL 分支均得 **0**，跳过映射下界。非空文本不裁剪首尾空格。多值与有序容器不得包含空字符串成员。
- 非空响应受 `min-choices`／`max-choices` 约束；选择题的 `max-choices=0` 表示不限制数量，排序题使用上文的范围规则。题目中不存在的选项会报错。未作答可得到零分；阻止学习者跳题属于宿主应用的交互策略。

数值填空使用 `single/integer` 或 `single/float`，绑定 `qti-text-entry-interaction`。整数限定在 ±9,007,199,254,740,991 内；整数文本及原始 JSON 整数字面量不接受小数点或指数，防止先舍入后误判。浮点数允许十进制科学计数法，拒绝 NaN、无穷与溢出。数值文本去掉首尾空白，全空白视为 NULL；普通字符串保持原文。

整数支持 `match_correct`；浮点题必须使用下列受限内联规则，避免将字符串匹配套到浮点比较上。数值 mapping 暂不支持。

| 数值规则结构 | 当前支持 |
|---|---|
| `qti-response-processing` | 一个 `qti-response-condition`，最多 128 个有序分支 |
| 分支 | 一个 `response-if`、若干 `response-else-if`、必需的最终 `response-else`；每个分支一个 SCORE 赋值 |
| 条件 | `qti-is-null` 或 `qti-equal`；操作数为 RESPONSE、其正确值或数字常量 |
| 数值相等 | exact、absolute、relative；容差为一或两个正数，边界默认包含，可分别排除 |
| 赋值 | `qti-set-outcome-value identifier="SCORE"`，内容为有限 float 常量 |

绝对容差以第一个操作数 x 为基准，比较第二个值 y 是否落在 `[x-t0, x+t1]`。相对容差按百分数计算为 `[x×(1-t0/100), x×(1+t1/100)]`；本库限定其第一个操作数为固定、非负的正确值或常量，负参考值可使用绝对容差。操作数顺序不会自动交换。比较使用 IEEE 754 双精度计算，不额外添加隐藏 epsilon。数值规则的 NULL 分支按作者赋值执行，未作答不强制归零。示例见 [numeric.xml](examples/numeric.xml)。

当前不包含 QTI 2、多个响应的复合题、record 类型、通用评分表达式、模板变量、反馈执行、试卷编序和完整 XSD 校验。不支持的评分结构、属性、交互会明确返回错误。本库实现上述子集，未声称通过 1EdTech 产品认证。0.2.0 扩展了公开枚举 `BaseType`、`Response` 和 `Template`；0.5.0 为 `Cardinality` 与 `Response` 新增 `Ordered`，SDK 的元信息基数联合类型也增加 `ordered`。使用穷尽模式匹配的调用者需要处理新增分支。

默认 XML 上限为 **1,048,576 UTF-16 码元、128 层、30,000 个元素**；可传 `Limits` 调整，深度不允许超过 256。响应 JSON 上限为 1,048,576 码元、16 层；每次作答最多 4,096 个值，每个值最多 65,536 码元。DOCTYPE 和处理指令不在支持范围内。

## 错误与命令行退出码

JSON 边界返回 `{ "ok": false, "error": { "code", "message", "location" } }`。XML 解析错误及已知位置的题目编译错误包含从 1 开始计数的行列位置；没有可定位 XML 节点的错误，其 `location` 为 `null`。

| 错误码 | 含义 |
|---|---|
| `invalid_xml` | XML 格式或命名空间语法错误 |
| `invalid_item` | 声明不一致、缺少必需内容或无效参数 |
| `invalid_package` | ZIP、路径、清单资源或依赖不一致 |
| `unsupported` | 当前 QTI 处理子集不支持的结构 |
| `invalid_response` | 响应形状、选项或数据无效 |
| `limit_exceeded` | 超过资源上限 |

CLI 成功退出码为 0；文件或评分错误为 1；命令格式错误为 2。`batch` 跳过空白行，每个非空行均输出一条带原始行号的结果；有任何失败行则最终退出 1，其他行仍会处理。

`inspect-package` 对可读取的题包返回 0，即使个别题目不兼容；调用者检查报告中的状态。`package-score` / `package-explain` 在所选资源不可用时返回 1 和具体错误。

## 开发与核对

```sh
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon info --target all
npm ci --prefix sdk --ignore-scripts
python tools/project.py check
```

最后一个命令会构建浏览器桥接模块与独立 SDK，运行 SDK 接入测试和 TypeScript 类型检查，并以固定提交版本的官方单选、多选、排序、配对题目进行 **30 个评分场景**核对，另检查 **12 个本地数值场景**、**8 个本地排序场景**、**11 个本地配对场景**和 **11 个本地选词场景**。CLI、桥接与 SDK 的结果必须一致，本地场景的评分解释也逐步对照，同时检查 CLI 错误退出码。排序官方题目的核对覆盖全部 6 种三项排列及两种 NULL 输入。预期值根据标准规则与题目声明编写，不由待测评分器生成。TypeScript 是 SDK 的开发依赖，由前一条 npm 命令安装；普通 MoonBit 核心测试不依赖它。

检查还对照 CLI 与 SDK 的完整题包报告及 2 个题包评分／解释场景，并验证不支持和未知资源的非零退出码。核心测试覆盖 Store/Deflate/数据描述符、CRC、解压限额、URI 编码、xml:base、缺失文件、长依赖链与循环；SDK 测试覆盖字节隔离、独立安装和对象生命周期。

跨题批量检查包含 8 组输入：混合成功／失败、全成功、重复及格式错误、空批次、带逗号／引号／公式前缀的 ID，以及独立排序题包、配对题包和选词题包。逐项对照 CLI 与 SDK 的完整 JSON 报告和 CSV 字节，并用 Python 标准库的独立 CSV 解析器检查列数、得分空值、错误码及文本转义。核心另覆盖整数原始词法、负分、非零 NULL 分与汇总溢出。

另检查固定官方 `gap_match.xml` 的一处声明冲突：原文件省略最大关联数，默认 1，与其两个标准配对不一致，预期返回 `invalid_item`。保留原文件的 SHA-256，并仅添加 `max-associations="0"`，对这个明确标注的派生版本运行 **8 个评分场景**。报告将其记为 `derived_cases`，原文件拒绝结果记为 `official_rejections`，与上述 30 个未修改官方场景分别列出。来源见 [固定官方文件](https://github.com/1EdTech/qti-examples/blob/0a92fbbb6d2e620a1f7fad19977be4c418246bc0/qtiv3-examples/packaging/items/gap_match.xml)。

官方 XML 首次运行时下载到 `_build/reference/`，校验固定 SHA-256 后使用，后续可用 `--offline` 运行。结构化结果默认保存到 `_build/validation.json`，也可用 `--output PATH` 指定位置。检查还覆盖批处理空行、失败后继续处理及退出码。普通 MoonBit 测试使用仓库内自编题目，依赖下载后可离线运行。

## 依据与依赖

- [QTI 3 规范、示例与评分模板](https://www.1edtech.org/standards/qti/index)
- [QTI 3 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/index.html)，特别是 Mapping、MapEntry、MapResponse、Match、Equal
- [官方样例固定版本](https://github.com/1EdTech/qti-examples/tree/0a92fbbb6d2e620a1f7fad19977be4c418246bc0/qtiv3-examples/packaging/items)
- `Milky2018/xml` 0.6.1：XML 与命名空间解析
- `moonbit-community/casefold` 0.1.7：Unicode case folding
- `moonbit-community/flate` 0.9.0：纯 MoonBit ZIP 解压、CRC 与资源限额
- `moonbitlang/x` 0.5.6：CLI 与测试的文件读写、进程退出

源码采用 Apache-2.0，见 [LICENSE](LICENSE)。官方样例不随源码重新分发；核对脚本下载的样例保留其上游许可。
