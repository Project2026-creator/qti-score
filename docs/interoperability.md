# 独立实现互通验证

本项目使用独立发布的 [LongsightGroup QTI 3](https://github.com/LongsightGroup/qti3) 验证原始题目 XML、评分与呈现。对照对象固定为 MIT 许可的 `@longsightgroup/qti3-core@0.13.3` 和 `@longsightgroup/qti3-player@0.13.3`，不修改其代码。MoonBit 与对照实现分别解析同一份 XML 并执行响应处理。

```sh
python tools/project.py build-web
npm install --prefix _build/interop --no-save --package-lock=false @longsightgroup/qti3-core@0.13.3 @longsightgroup/qti3-player@0.13.3 playwright-core@1.64.1
node tools/independent_test.mjs --browser --output _build/independent-validation.json
```

浏览器检查需要已安装 Chrome。省略 `--browser` 可执行两个核心实现之间的对照。额外依赖只用于验证，不进入核心库或 SDK 的运行依赖；报告记录外部版本、原 XML 的 SHA-256、响应、对照结果和差异。CI 执行相同命令。

| 内容 | 验证结果 |
|---|---|
| Choice、Multiple Choice、Match、Associate、Hottext、Numeric、动态反馈 | 共 22 个响应场景的全部已声明 outcome 及 modal 反馈选择一致 |
| 独立播放器载入新动态反馈题 | 原 XML 未修改，初始隐藏反馈未显示 |
| 独立播放器实际作答 | 得 2 分；定点打印与嵌套可见性符合预期 |
| 独立播放器保存、恢复 | 已恢复；其响应再交给 MoonBit，仍得 2 分 |
| Inline Choice 的 `qti-label` | 存在输入兼容差异，未计入通过场景 |
| 有序变量的自定义 delimiter | 存在呈现差异，详情见下文 |

固定版本的外部解析器拒绝 `examples/inline-choice.xml` 中作为交互直接子元素的 `qti-label`。该原文件同时由官方 ASI 3.0.1 及 Item XSD 检查，检查通过；本项目保留标准结构并记录诊断，未删除标签来获得通过。

外部播放器显示 `EVIDENCE` 有序结果时，使用 `收集证据, 调整教学`，没有采用题目指定的 `delimiter=" → "`。MoonBit 输出 `收集证据 → 调整教学`。数值结果、单值打印与反馈条件一致，这一文字呈现差异单独保留。验证脚本明确检查这两个固定版本的差异，升级外部实现时需重新核对。

这些结果证明所列题目在两个独立实现中的交换与评分行为，以及一个独立浏览器播放器中的实际呈现和响应回传。验证范围未包含外部 LMS 的账号、完整测验编序、内容包往返和 QTI Result Reporting 接收。结果 XML 另经官方 XSD 和独立读取程序检查；这些检查与产品认证分别陈述。
