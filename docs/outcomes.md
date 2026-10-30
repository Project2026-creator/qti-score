# 分数换算与测验反馈

0.23.0 在现有评分和条件导航上增加作者定义的阈值换算与测验反馈。核心读取标准 XML、计算结果和反馈可见性，页面呈现核心返回的文字与分值。

在 [试卷运行器](http://127.0.0.1:4173/web/test.html) 选择“体验分数换算与反馈”，或运行：

```sh
python tools/project.py build-web
moon run cmd/main -- test-run web/outcome-test-package.zip outcome-test examples/outcome-actions.json
moon run cmd/main -- test-run web/outcome-test-package.zip outcome-test examples/outcome-review-actions.json
```

| 作答文件 | SCORE | PERCENT | LEVEL |
|---|---:|---:|---|
| `outcome-actions.json` | 4 | 100 | mastered |
| `outcome-review-actions.json` | 0 | 0 | review |

示例的基础部分逐题提交，两题各 1 分；迁移部分统一提交，测量题最多 2 分。基础部分结束时的 developing 或 review 反馈会保留，迁移部分更新整卷等级后仍可回看。SCORE、PERCENT、LEVEL 是示例作者声明的结果变量，核心没有根据这些名称自动换算的规则。

## 阈值换算

结果声明中的 `qti-interpolation-table` 定义阈值表，`qti-lookup-outcome-value` 是赋值规则，放在响应／试卷结果处理或其条件分支中：

```xml
<qti-outcome-declaration identifier="LEVEL" cardinality="single" base-type="identifier">
  <qti-interpolation-table default-value="review">
    <qti-interpolation-table-entry source-value="3" target-value="mastered"/>
    <qti-interpolation-table-entry source-value="1" target-value="developing"/>
    <qti-interpolation-table-entry source-value="0" target-value="review"/>
  </qti-interpolation-table>
</qti-outcome-declaration>
```

```xml
<qti-lookup-outcome-value identifier="LEVEL">
  <qti-variable identifier="SCORE"/>
</qti-lookup-outcome-value>
```

引擎按作者文档顺序查找，第一条满足“输入大于等于 source-value”的记录生效。`include-boundary="false"` 将该行改为严格大于。表不会自动排序，相同阈值仍以先匹配的行优先；建议像示例一样按阈值从高到低编写。

这个标准表执行阶梯阈值换算，不计算相邻两点之间的直线。输入高于所有阈值时仍按第一条满足的行取值；低于全部阈值则取表的 default-value，未设置时为 NULL。本实现把 NULL 输入视为没有匹配行，同样使用表的 fallback。表的 fallback 与结果变量声明的 `qti-default-value` 分开：每次 lookup 都覆盖目标当前值，不会因没有匹配而沿用旧分数。

源表达式须为 single integer／float 或 NULL；目标是声明了阈值表的 single outcome。目标值支持当前标量子集：float、integer、identifier、string、boolean、directedPair，并按声明类型检查。结果为 integer 时仍执行安全整数范围检查。match-table、duration、record 和容器目标暂不支持。

每表最多 1024 行，每个处理程序总共最多 8192 行；查找消耗现有表达式执行预算。普通元信息不返回阈值、目标值和 fallback；显式开发者解释接口可记录命中行与赋值。

## 反馈何时出现

`qti-test-feedback` 可位于试卷或考试部分，使用试卷级 identifier 结果变量控制。控制变量须为 single 或 multiple，单值比较相等、多值判断是否包含；NULL 不匹配任何 identifier。`show-hide="show"` 在匹配时显示，hide 在不匹配时显示。

```xml
<qti-test-feedback identifier="mastered" outcome-identifier="LEVEL"
    show-hide="show" access="atEnd" title="达到掌握水平">
  <qti-content-body><p>可以回看各部分结束时的建议，再尝试迁移练习。</p></qti-content-body>
</qti-test-feedback>
```

| 所属范围与 access | 执行行为 |
|---|---|
| test + during | 首次成功执行结果处理后，根据最新已提交结果更新；整卷结束后不再作为进行中反馈呈现 |
| part + during | 当前部分自身成功执行结果处理后更新；尚未提交的新部分不沿用此前部分的触发时机 |
| part + atEnd | 实际结束该部分时选择并保存可见反馈，后续部分不重新判断历史反馈 |
| test + atEnd | 整卷完成时按最终结果选择；不能在草稿阶段提前读取 |

保存草稿、查看状态、暂停或恢复时不额外执行结果处理。simultaneous 部分在统一提交后更新反馈。被条件跳过的部分不产生部分结束反馈；提前退出或到时收卷会完成实际活动部分的结束生命周期。全部入口条件不满足而整卷直接完成时，整卷 atEnd 仍可依据声明初值选择，不能为反馈伪执行响应处理。

题目的 `show-feedback` 控制题目反馈；试卷与部分反馈使用各自的 access 和结果变量。多个反馈块可复用相同 identifier，不与题目引用或分节标识符混用唯一性规则。输出按作者顺序保留同一范围内可见的反馈。

人工待评是有效状态：结果仍保留 NULL，作者可据此提供待评提示。若作者给阈值表设置了数值 fallback，NULL 输入也会得到那个作者指定值；需要保持待定时，应省略 fallback 或在查表之前显式处理 NULL。页面同时保留待评状态，不能将换算结果当作人工评分已经完成的依据。

响应或试卷结果处理的技术错误与作者主动产生 NULL 分开处理：普通失败动作整体回滚；强制收卷保留错误诊断，抑制新生成的进行中和结束反馈，已成功归档的此前部分反馈仍可查看。这是本实现的错误处理策略，避免基于失败的计算生成成绩建议。

## 接入与内容范围

SDK 的 `session.describe().test_feedback` 与结果报告的 `test_feedback` 结构一致：

```ts
{
  during: TestFeedbackView[],
  completed_parts: { part_identifier, title, completed_at, feedback: TestFeedbackView[] }[],
  at_end: TestFeedbackView[]
}
```

View 包含 scope、scope_identifier、identifier、outcome_identifier、access、title、text。`completed_at` 是宿主提供的结束动作时间，单位为秒；题目与部分时长仍按现有限时规则计算。结束部分记录保留当时可见的反馈，不向候选人公开历史结果快照或未匹配反馈。返回 JSON 是独立副本，宿主修改它不会影响其他会话。

快照继续记录动作，恢复时在相同结束边界重新构建历史反馈，不读取快照中伪造的反馈或分数。试卷编译对象的 `describe()` 仅提供 has_feedback 标记，不返回作者的反馈内容、控制条件或换算表。标准结果 XML 继续导出带类型的结果变量；反馈历史保留在 JSON 中，不向结果 XML 添加非标准节点。

本版本支持 `qti-content-body` 内安全静态文字与基础块／内联格式，按纯文本呈现。可省略 content-body，也可只提供 title。打印变量、嵌套动态反馈、外部样式、catalog、脚本、交互及其他内容明确报错。

规范依据为 [ASI 3.0.1 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/imsqti_asi_v3p0p1_infomodel_v1p0.html) 的 InterpolationTable、LookupOutcomeValue 和 TestFeedback，以及 [实施指南](https://www.imsglobal.org/spec/qti/v3p0/impl/) §4.6.2。示例结构与导出结果分别由固定版本官方 XSD 校验，具体行为由核心、SDK、CLI 与浏览器回归验证。
