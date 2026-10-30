# 前置条件与分支

0.22.0 可以根据已提交作答控制题目、分节和后续考试部分。示例将形成性评价诊断连接到补救或迁移任务，再进入反思部分；选择退出选项会直接结束本次练习。

在 [试卷运行器](http://127.0.0.1:4173/web/test.html) 选择“条件导航”，或运行：

```sh
python tools/project.py build-web
moon run cmd/main -- test-run web/conditional-test-package.zip conditional-test examples/conditional-actions.json
```

| 作答文件 | 实际呈现路径 | 试卷 SCORE |
|---|---|---|
| `conditional-actions.json` | diagnostic → advanced → reflection-item | 4 |
| `conditional-catchup-actions.json` | diagnostic → remedial → reflection-item | 2 |
| `conditional-exit-actions.json` | diagnostic，随后退出 | 0 |

这三个文件使用相同的试卷和题目。诊断题 A 得 1 分，B 为结束选项，C 进入补救；迁移题输入 100 得 2 分。分支在 `next` 离开当前题时生效，提交后的反馈仍可查看。完整例子见 [试卷 XML](../examples/conditional-test.xml)。

## 执行次序

进入一个尚未进入的考试部分或分节时，先按外到内检查 `qti-pre-condition`，再检查题目引用的条件。多个条件按文档顺序全部满足才能进入；false 或 NULL 都跳过该范围。首次进入前，试卷结果变量使用声明默认值，未声明默认的数值单值为 0；条件不会自行执行试卷结果处理或重置当前结果。

固定顺序的 `linear/individual` 部分中，保存仍只校验草稿；修改后需先 `submit`。`next` 结束当前尝试，必要时执行该题的响应处理和试卷结果处理，再按题目、由内到外自然结束的分节、考试部分的顺序查找分支。每个范围按文档顺序选首个为真的 `qti-branch-rule`；false 和 NULL 继续查找。已提交且未修改的作答不会重复增加尝试次数。未提交的可选空答在离开时形成一次尝试；被条件排除且从未呈现的题则不执行响应处理。

```xml
<qti-assessment-item-ref identifier="diagnostic" href="items/single.xml">
  <qti-branch-rule target="advanced-section">
    <qti-equal>
      <qti-variable identifier="diagnostic.SCORE"/>
      <qti-base-value base-type="float">1</qti-base-value>
    </qti-equal>
  </qti-branch-rule>
</qti-assessment-item-ref>
```

条件可以读取当前试卷结果和题目变量；响应只读取已提交值，未提交题目的结果变量使用声明初值，且不执行响应处理。试卷汇总仍只收集已经提交的题目结果。`qti-test-variables` 与 `weight-identifier` 限于试卷结果处理，先将它们汇总为试卷结果再供条件引用。跳转进入分节内部某题时，仍先检查其尚未进入的祖先分节条件。自然结束分节时，即使尾部题目被条件排除，也会处理该分节的分支。

`finish_part` 明确结束当前部分：有活动题目／分节条件时，只收集已呈现题目的提交，其余位置记为未呈现；随后处理部分分支与目标部分条件。没有这些条件时保留既有整部分提交行为。到达限时时由 `tick` 强制收卷；处理或导航表达式出错时保留诊断与 NULL 试卷结果，完成会话以便导出。普通动作出错时，时钟、分数、路径与快照一起回滚。

## 跳转范围与支持边界

| 规则所属范围 | 接受的目标 |
|---|---|
| 题目引用 | 同部分中尚未呈现的后续题目／分节；`EXIT_SECTION`、`EXIT_TESTPART`、`EXIT_TEST` |
| 分节 | 同部分中该分节结束之后的题目／分节；`EXIT_TESTPART`、`EXIT_TEST` |
| 考试部分 | 后续考试部分；`EXIT_TESTPART`、`EXIT_TEST` |

`EXIT_TESTPART` 先结束当前部分并完成其收卷流程，再按该部分的分支决定后续部分；`EXIT_TEST` 直接结束整卷。`EXIT_SECTION` 在题目引用上退出最近的包含分节。分节自身使用这一目标暂时返回 `unsupported`。三个退出名称保留，不能用作作者标识符。缺失目标、回跳、跳入已完成范围和跨部分的题目跳转在编译时拒绝。

本版本在 `linear/individual` 内执行题目与分节条件；`nonlinear` 内按标准忽略这两级条件，仍校验其 XML 与表达式类型。考试部分条件始终生效，包括内部为 nonlinear 或 simultaneous 的部分；simultaneous 的部分分支在集中提交和试卷结果处理后运行。

活动题目／分节条件不能与该部分中的选择、放回抽样或有效乱序组合。外部分节引用内的活动条件，以及从外部直接跳转到引用文档的后代节点，暂时返回 `unsupported`；外部分节本身仍可作为目标。空范围上的活动条件也明确拒绝。条件与分支总数最多 1024，原有编译、表达式和会话限额继续适用。

## 说明、恢复与结果

候选人说明支持试卷、考试部分与分节的静态 `qti-rubric-block`：`view` 必填，可为多个角色；包含 candidate 才进入学习者元信息。支持省略 `use` 或使用 instructions、navigation、scoring。内容使用 `qti-content-body` 中的安全静态文字，不执行脚本、动态模板或交互。

`entry.instructions` 与 `state.current.instructions` 按整卷、部分、外层到内层分节排列。页面随每题保留相关分节说明，并可重新查看已进入部分的说明；跳过部分的说明不加入历史。返回的 JSON 可由宿主独立修改，不影响后续会话或其他实例。

会话摘要和 JSON 结果增加 `presented`、`skipped`。规则排除的题以 `initial` 导出，响应为 NULL、结果变量为声明初值、尝试和时长为 0；不参加已提交题目的汇总，也不成为人工待评。`all_items_scored` 只要求实际需要评分的题完成评分。标准 XML 的 sequenceIndex 保留组装位置，JSON 同时保留排除状态。

快照记录已接受的动作，恢复时重跑同一组条件、评分和跳转。规则、说明、题目、控制或组卷种子改变后不能继续使用原快照。

规则依据为 [QTI ASI 3.0.1 信息模型](https://www.imsglobal.org/sites/default/files/spec/qti/v3/info/imsqti_asi_v3p0p1_infomodel_v1p0.html) 的 PreCondition、BranchRule 与 TestRubricBlock，以及 [实施指南](https://www.imsglobal.org/spec/qti/v3p0/impl/) 的 §4.5.3 和 §4.6.1。本页列出已实现的执行范围；全量自适应交付、模板处理和完整内容呈现仍待实现。
