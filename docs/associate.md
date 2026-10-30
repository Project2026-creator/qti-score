# 同组无向关联

0.24.0 增加 `qti-associate-interaction` 和 `pair` 类型。学习者从同一组选项中选出两项建立关联；`A B` 与 `B A` 表示同一配对。适合概念联系、同义词和理论与实例匹配。原有 Match 的来源、目标方向保持原语义。

```js
import { compileItem } from './sdk/index.mjs';
const item = compileItem(xml);
try {
  item.score({ RESPONSE: ['ActiveLearning Constructivism', 'Memory Cognitivism'] });
  console.log(item.describe().association);
} finally { item.dispose(); }
```

响应声明使用 `single/pair` 或 `multiple/pair`，沿用字符串或字符串数组接口。多个配对的排列顺序不影响完全匹配；两端区分大小写，XML 空白折叠为一个空格。核心按 ASCII 字典顺序保存两端，因此题目的正确响应、映射键、类型化表达式及会话结果有相同表示。`map_response` 支持部分得分、默认映射和分数上下界，`match_correct` 仍按整个响应判定一分或零分。

非空响应检查 `min-associations`、`max-associations`、每个选项的 `match-min`／`match-max` 和双方的 `match-group`。最大值 0 表示不设上限；整体最大值缺省为 1，single 必须使用该上限。每项必须声明 `match-max`。未知端点、自关联、同一配对重复提交（包括反向重复）会返回 `invalid_response`。正确答案和映射中的端点在编译时检查，反向等价的重复映射键返回 `invalid_item`。NULL 和空数组保留未作答状态，不因最低数量要求变为零个错误配对。

`describe().association` 返回整体限制、`shuffle` 以及单个 `choices` 数组。各选项包含 `identifier`、`text`、`match_min`、`match_max`、`fixed` 和 `match_group`。元信息每次重新分配，不含正确配对或映射分值。`BaseType` 公开枚举新增 `Pair`，SDK 的 single item `base_type` 联合类型新增 `'pair'`；穷尽匹配这些类型的调用方需处理新分支。

核心元信息保持作者顺序，呈现端在 `shuffle=true` 时打乱非固定选项，并保留 `fixed=true` 的位置。工作台与整卷播放器共用配对控件，支持移除、次数提示、反向重复提示及恢复已保存的配对。选项呈现顺序可在重新打开页面或题目时变化，当前快照保存作答与评分过程，不保存选项显示顺序。

0.24.0 新增内部题目字段，编译试卷的身份值随之变化；旧版会话快照不能直接恢复到本版本。升级前请在原版本完成旧会话并导出结果。本版本内对相同内容包、种子和规则生成的快照可正常恢复。

整卷演示可在测验页点击“体验同组无向关联”。也可运行：

```sh
python tools/project.py build-web
moon run cmd/main -- test-run web/associate-test-package.zip associate-test examples/associate-actions.json
```

示例将三组学习理论关系计为三分，导出使用标准 `baseType="pair"` 的响应变量。草稿恢复、类型化规则、题包和结果导出均由 MoonBit 核心处理。

支持范围为静态文字选项、简单文字格式及上述数量约束，每个交互最多 512 个选项。图形关联、模板变量控制选项可见性、图片／音视频／MathML 选项和完整富文本呈现仍待实现；遇到这些结构会明确报错。

验证使用 [1EdTech 固定版本的打包示例](https://github.com/1EdTech/qti-examples/blob/0a92fbbb6d2e620a1f7fad19977be4c418246bc0/qtiv3-examples/packaging/items/associate.xml)及 [BPIG 示例](https://github.com/1EdTech/qti-examples/blob/0a92fbbb6d2e620a1f7fad19977be4c418246bc0/QTI3_BPIG_Examples/items/QTI3-associate.xml)，按哈希校验原文件后执行评分。ASI 与结果 XML 另由官方 XSD 校验。这些检查验证外部样例输入和标准文档结构；尚未验证独立测评产品导入结果的实际行为。
