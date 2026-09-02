# T-24 Review: lecture_btree.html 更新（getBorrowed 案例复盘化）

- **Reviewer**: w2（非作者；作者 w1-droid1）
- **Reviewed SHA**: `be50a85` （分支 `worktree/silver-cloud-e24f`）
- **基线**: main @ `216e8d8`（含 T-23）
- **契约**: `.agents/tasks/T-24-lecture-update/task.md`

## Verdict: ✅ APPROVE

## 核查过程与结果

### 1. 改动范围

`git diff --name-only 216e8d8..be50a85` → 仅 `docs/lecture_btree.html`（+37 −22）。
`docs/chronicle.md` 及其他所有文件零改动。✅ 符合 Ownership（仅此一个文件）。

### 2. 契约 6 项逐条对照

| # | 契约要求 | 结果 | 证据 |
|---|---------|------|------|
| 1 | 目录与标题改为现状（锚点 id 保留） | ✅ | TOC L28-29：`第四部分 · 读取路径：get 与零拷贝的取舍` / `4.1 案例复盘：getBorrowed 的设计与移除`；正文 h2/h3 同步；`id="part4"` / `id="s41"` 保留，`href` 锚点无断链 |
| 2 | §4.1 改案例复盘口吻；代码示例保留 + 标注移除 | ✅ | 引言改为「历史上曾存在…已于 T-23 移除」；新增 `note warn` 框说明删除范围；两个代码块首行均加 `<span class="cm">// 已于 T-23 移除 — 仅作历史/教学参考</span>`，示例本体原样保留；并补充「生产代码零调用者」的移除事实与移除决策总结 |
| 3 | 危险框原文保留 + 补充句 | ✅ | 逐字对比基线：原文 4 行完全一致，仅追加 `<br>` + 「正因这个坑无法在类型层面消除（Zig 的 `?[]const u8` 装不下三种语义），最终选择移除 API 而非修补」——与契约要求的补充句几乎逐字对应 |
| 4 | 其余散落引用过去时/加注 | ✅ | 头部 tag「零拷贝借用（已移除）」；§1.1 注「API 已于 T-23 移除，见第四部分案例复盘」；§1.x「原 getBorrowed 也依赖此机制…已于 T-23 移除」；§2.2「热路径**曾**通过 getBorrowed（已于 T-23 移除）」；第三部分结尾、§4.3 生命期框、文末总结段均已过去时/加注 |
| 5 | 总结表行保留 + 状态注明 | ✅ | L884：「getBorrowed 溢出返 null（已移除）」，教训列保留，缓解列改「API 已于 T-23 移除（null 三义性无法在类型层面消除）；统一用 get()」 |
| 6 | 沿用现有样式 | ✅ | 仅使用基线已有 class（`note`/`note warn`/`note danger`/`cm`/`kw`/`fn`/`ty`/`nu`/`muted`/`strong` 等）；`<style>` 块无改动，无新样式 |

### 3. 全文 getBorrowed 口吻抽查（21 处）

逐一核对剩余 21 处引用：均为「过去时 / 已移除标注 / 案例复盘语境 / 契约要求保留的教学内容」，无「现役 API 使用指南」口吻残留。

**边界情况（不阻塞）**：L578 `get` 代码示例内注释「同 getBorrowed 下沉，但叶层调 findInLeaf（堆拷贝）」为基线原有文字，现在时措辞未加注。判定为可接受：该注释紧邻 §4.1 的移除说明，读者语境中 getBorrowed 已明确为上文刚复盘过的历史案例，且非「使用指南」性质。建议（非必须）后续顺手改为「同（已移除的）getBorrowed 下沉」。

### 4. 契约 acceptance 命令

`! rg -q 'getBorrowed' docs/lecture_btree.html || rg -c ... && python3 html.parser && git diff --stat` → **exit 0** ✅（HTML 可无异常解析，改动只落在 lecture_btree.html，无未提交残留）。

## 结论

6 项契约要求全部满足，无越权改动，无样式引入，教训内容（null 多义性）按契约完整保留并强化。**APPROVE**，1 条非阻塞建议见上。
