# 打印变量与动态反馈

0.25.0 增加 `qti-printed-variable`、`qti-feedback-inline` 与 `qti-feedback-block` 的安全纯文本呈现。题干、选项、正文、题目候选人说明和题目反馈可按结果变量更新；测验与部分反馈支持打印结果变量。显示内容由 MoonBit 核心计算，浏览器只接收已选出的文字，不执行作者提供的 HTML 或脚本。

```xml
<qti-feedback-block identifier="submitted" outcome-identifier="NOTICE">
  <qti-content-body>
    <p>本次得分：<qti-printed-variable identifier="SCORE" format="%.1f"/>。</p>
  </qti-content-body>
</qti-feedback-block>
```

反馈控制变量必须是已声明的 single／multiple identifier outcome。`show-hide` 缺省为 `show`；`hide` 在变量不匹配时显示，NULL 不匹配标识符。支持嵌套反馈，父级隐藏时不呈现子级；inline 内不能嵌套 block，非自适应反馈内不能包含交互。block 内容使用 `qti-content-body`，inline 内容直接置于该元素内。测验反馈的内容模型与题目反馈不同，不能在 `qti-test-feedback` 中嵌入题目的 inline／block 反馈。

打印变量只读取声明的 outcome，直接引用 response 或未声明变量会报错。模板变量与模板处理尚未实现。NULL 显示为空；字符串、标识符、布尔值和配对值保持为文字；multiple／ordered 使用 `delimiter` 分隔，默认 `;`。ordered 可用从 1 开始的常数 `index`，越界显示为空。

数值格式支持整数 `%i`、兼容写法 `%d`，以及 `%f`、`%.0f` 至 `%.12f`。`%i` 可用 2–36 的常数 `base`。浮点定点输出根据实际 IEEE-754 值作最近值、偶数舍入，避免先乘十的幂造成的溢出或二次舍入；例如 `1.005` 的二进制值按两位小数输出为 `1.00`。缺省格式使用内核的数值文本表示。科学计数格式、宽度、标志、动态精度／进制、power-form 与 record field 尚未支持，编译时明确报错。单次渲染内容最多 65,536 个 UTF-16 单元，超限以 `…[content limit]` 标记截断，并保留完整 Unicode 字符。

```js
const item = compileItem(xml);
try {
  const view = item.present({ RESPONSE: 'Adjust' });
  console.log(view.item, view.outcomes, view.feedback);
} finally { item.dispose(); }
```

`present()` 是显式提交计算接口，返回当次结果、已渲染题目描述和可见 modal 反馈。`describe()` 保持初始结果状态，不执行评分。包含动态正文的题目使用 `kind: 'composite'` 和 `passage`，即使只有一个响应；元信息带 `dynamic_content: true`，接入方应按响应列表及文段位置呈现。对应 MoonBit 接口为 `AssessmentItem::presentation_json`。

整卷播放器使用已接受的结果呈现内容，保存草稿不会执行响应处理。再次作答时保留上次已提交结果的正文，下一次提交后才更新；simultaneous 部分在交卷前不显示草稿对应的反馈。`show-feedback=false` 同时抑制动态提示和 modal 反馈。部分结束时把当时已经渲染的测验反馈归档，后续累计分数变化不会改写历史，快照重放可重建相同结果。

工作台新增“动态学习反馈”，测验页新增“体验变量与动态反馈”。示例的两个部分最终得到 4.0 分，第一部分结束反馈保留 2.0 分。源文件见 `examples/dynamic-feedback.xml`、`dynamic-test.xml` 和 `dynamic-actions.json`。0.25.0 的处理型题目表示发生变化，旧版本快照请在生成它的版本中完成并导出结果。

当前呈现保留安全文字及顺序，不保留完整富文本布局；MathML、媒体、catalog、模板控制和测验 rubric 内的动态打印仍待实现。规范依据为 [ASI 3.0.1 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/imsqti_asi_v3p0p1_infomodel_v1p0.html)，独立实现对照范围与已发现差异见 [互通验证](interoperability.md)。
