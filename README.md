# QTI Score

A MoonBit library for compiling and scoring a focused subset of QTI 3 items. Supports single choice, multiple choice, and string text entry with the standard `match_correct` and `map_response` templates.

QTI Score 将 QTI 3 题目编译成可重复使用的评分对象。核心库负责 XML 命名空间、响应类型、标准答案和映射规则；命令行与浏览器使用同一份实现。适用于测验平台接入、题目迁移验证和教育技术课程中的标准实验。

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

# 同一题目的多次作答，逐行输出 JSON
moon run cmd/main -- batch examples/multiple.xml examples/attempts.jsonl

# 构建并启动浏览器工作台
python tools/project.py serve
```

浏览器打开 [http://127.0.0.1:4173/web/](http://127.0.0.1:4173/web/)。可切换三种示例、编辑或导入 XML，并查看作答和评分结果。示例界面用纯文本呈现题干，不实现完整 QTI 内容渲染；`shuffle` 等呈现信息不改变评分计算，演示按原文顺序列出选项。

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
| `Item::describe()` | 返回题目、交互和选项的纯文本元信息 |
| `evaluate_json(xml, response_json)` | 不抛异常的 JSON 宿主边界 |
| `describe_json(xml)` | 不提交作答，编译并返回 JSON 元信息 |

响应 JSON 为单个对象：

```json
{"RESPONSE":["A","C"]}
```

单值用字符串；多值用字符串数组；`null` 或省略 `RESPONSE` 表示未作答。未知成员、重复键、数字或布尔响应会被拒绝。单基数响应必须用字符串，不能用单元素数组代替。

评分对象包含：

```json
{"score":2,"status":"answered","matches_correct":true}
```

`matches_correct` 表示与作者声明的标准响应完全匹配，与映射得分分别计算。未声明标准响应时为 `null`。部分得分、同分替代答案都不自动等于“完全匹配”。

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

首版不包含 QTI 2、多个响应的复合题、数值填空、ordered／record 类型、自定义评分表达式、模板变量、反馈执行、试卷编序和完整 XSD 校验。不支持的评分结构、属性、交互会明确返回错误。本库实现上述子集，未声称通过 1EdTech 产品认证。

默认 XML 上限为 **1,048,576 UTF-16 码元、128 层、30,000 个元素**；可传 `Limits` 调整，深度不允许超过 256。响应 JSON 上限为 1,048,576 码元、16 层；每次作答最多 4,096 个值，每个值最多 65,536 码元。DOCTYPE 和处理指令不在支持范围内。

## 错误与命令行退出码

JSON 边界返回 `{ "ok": false, "error": { "code", "message", "location" } }`。XML 错误包含从 1 开始计数的行列位置，其余错误的 `location` 为 `null`。

| 错误码 | 含义 |
|---|---|
| `invalid_xml` | XML 格式或命名空间语法错误 |
| `invalid_item` | 声明不一致、缺少必需内容或无效参数 |
| `unsupported` | 当前 QTI 处理子集不支持的结构 |
| `invalid_response` | 响应形状、选项或数据无效 |
| `limit_exceeded` | 超过资源上限 |

CLI 成功退出码为 0；文件或评分错误为 1；命令格式错误为 2。`batch` 跳过空白行，每个非空行均输出一条带原始行号的结果；有任何失败行则最终退出 1，其他行仍会处理。

## 开发与核对

```sh
moon fmt --check
moon check --target all --deny-warn
moon test --target all --deny-warn
moon info --target all
python tools/project.py check
```

最后一个命令会构建浏览器桥接模块，并以固定提交版本的官方单选、多选题目进行 **14 个评分场景**的核对，检查 CLI 与编译后的 MoonBit JS 桥接结果一致，同时检查 CLI 错误退出码。预期值根据标准模板及题目本身的映射编写，不由待测评分器生成。

官方 XML 首次运行时下载到 `_build/reference/`，校验固定 SHA-256 后使用，后续可用 `--offline` 运行。结构化结果默认保存到 `_build/validation.json`，也可用 `--output PATH` 指定位置。检查还覆盖批处理空行、失败后继续处理及退出码。普通 MoonBit 测试使用仓库内自编题目，依赖下载后可离线运行。

## 依据与依赖

- [QTI 3 规范、示例与评分模板](https://www.1edtech.org/standards/qti/index)
- [QTI 3 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/imsqti_asi_v3p0p1_infomodel_v1p0.html)，特别是 Mapping、MapEntry、MapResponse、Match
- [官方样例固定版本](https://github.com/1EdTech/qti-examples/tree/0a92fbbb6d2e620a1f7fad19977be4c418246bc0/qtiv3-examples/packaging/items)
- `Milky2018/xml` 0.6.1：XML 与命名空间解析
- `moonbit-community/casefold` 0.1.7：Unicode case folding
- `moonbitlang/x` 0.5.6：CLI 与测试的文件读写、进程退出

源码采用 Apache-2.0，见 [LICENSE](LICENSE)。官方样例不随源码重新分发；核对脚本下载的样例保留其上游许可。
