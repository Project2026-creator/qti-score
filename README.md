# QTI Score

A MoonBit library for importing QTI 3 ZIP content packages and scoring a focused subset of items. Supports choice, text and numeric entry, per-item compatibility reports, developer explanations, and an ESM JavaScript SDK backed by the same MoonBit core.

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

浏览器打开 [http://127.0.0.1:4173/web/](http://127.0.0.1:4173/web/)。可切换四种示例、编辑或导入 XML，并查看作答和评分结果。勾选“记录评分过程”后，提交作答会显示分支判断、映射贡献与分值限制。示例界面用纯文本呈现题干，不实现完整 QTI 内容渲染；`shuffle` 等呈现信息不改变评分计算，演示按原文顺序列出选项。

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

响应 JSON 为单个对象：

```json
{"RESPONSE":["A","C"]}
```

标识符和文本单值用字符串，多值用字符串数组；数值题还接受有限 JSON 数字，例如 `{"RESPONSE":100.5}`。`null` 或省略 `RESPONSE` 表示未作答。未知成员、重复键、布尔响应会被拒绝；非数值题不能接收数字。单基数响应不能用单元素数组代替。类型化 API 对数值响应提供 `Response::Number(Double)`，也接受数值文本。

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
- 每道题一个 `RESPONSE`，一个 `single/float` 类型的 `SCORE`，以及一个选择或文本填空交互。标识符采用 ASCII NCName 子集；题干与文本答案支持 Unicode。
- 单选／多选使用 `identifier` 类型；文本填空使用 `single/string`。支持正确答案、映射、分值上下界和可选的初始 SCORE 值。
- 识别 `purl.imsglobal.org/spec/qti/v3p0/rptemplates/` 和官方示例中旧的 `www.imsglobal.org/question/qti_v3p0/rptemplates/` 地址；两者均接受 HTTP／HTTPS 和可选 `.xml` 后缀。匹配完整 URI，不根据文件名猜测模板，不下载模板。
- `match_correct` 在完全匹配时固定赋值 **1**，其他情况赋值 **0**。`normal-maximum` 是元信息，不缩放该模板的分数。
- 多值完全匹配采用无序多重集比较，保留重复次数；`map_response` 对每个不同输入值只计一次，再对总和应用上下界。
- 映射中的未知有效选项使用 `default-value`，省略时默认 **0**。文本映射按文档顺序取第一个匹配项，`case-sensitive` 默认 `false`，使用 Unicode case folding；标识符始终区分大小写。建议把具体的大小写敏感条目放在较宽泛的条目前。同名键及重复的不区分大小写键被拒绝。
- 空字符串、空多值容器与 `Null` 按 QTI NULL 处理。两种模板的 NULL 分支均得 **0**，跳过映射下界。非空文本不裁剪首尾空格。多值容器不得包含空字符串。
- 非空响应受 `min-choices`／`max-choices` 约束；`max-choices=0` 表示不限制数量。题目中不存在的选项会报错。未作答可得到零分；阻止学习者跳题属于宿主应用的交互策略。

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

当前不包含 QTI 2、多个响应的复合题、ordered／record 类型、通用评分表达式、模板变量、反馈执行、试卷编序和完整 XSD 校验。不支持的评分结构、属性、交互会明确返回错误。本库实现上述子集，未声称通过 1EdTech 产品认证。0.2.0 扩展了公开枚举 `BaseType`、`Response` 和 `Template`；使用穷尽模式匹配的调用者需要处理新增分支。

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

最后一个命令会构建浏览器桥接模块与独立 SDK，运行 SDK 接入测试和 TypeScript 类型检查，并以固定提交版本的官方单选、多选题目进行 **14 个评分场景**核对，另检查 **12 个本地数值场景**。CLI、桥接与 SDK 的结果必须一致，数值评分解释也逐步对照，同时检查 CLI 错误退出码。预期值根据标准规则与题目声明编写，不由待测评分器生成。TypeScript 是 SDK 的开发依赖，由前一条 npm 命令安装；普通 MoonBit 核心测试不依赖它。

检查还对照 CLI 与 SDK 的完整题包报告及 2 个题包评分／解释场景，并验证不支持和未知资源的非零退出码。核心测试覆盖 Store/Deflate/数据描述符、CRC、解压限额、URI 编码、xml:base、缺失文件、长依赖链与循环；SDK 测试覆盖字节隔离、独立安装和对象生命周期。

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
