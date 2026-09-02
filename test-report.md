# T-24 Test Report: lecture_btree.html 更新

- **Tester**: w2（非作者；作者 w1-droid1）
- **Tested SHA**: `be50a85` （分支 `worktree/silver-cloud-e24f`）
- **基线**: main @ `216e8d8`
- **日期**: 2026-09-02

## Result: ✅ PASS

## 测试项

### T1. 改动范围检查（必须只动 docs/lecture_btree.html）

```
$ git diff --name-only 216e8d8..be50a85
docs/lecture_btree.html
$ git diff --stat 216e8d8..be50a85
 docs/lecture_btree.html | 59 +++++++++++++++++++++++++++++------------------
 1 file changed, 37 insertions(+), 22 deletions(-)
```

**PASS** — 单文件，符合 Ownership。

### T2. 契约 acceptance 命令原样执行

```
$ cd <worktree> && ! rg -q 'getBorrowed' docs/lecture_btree.html || rg -c 'getBorrowed' docs/lecture_btree.html >/dev/null && python3 -c "import html.parser,sys; p=html.parser.HTMLParser(); p.feed(open('docs/lecture_btree.html').read())" && git diff --stat
（exit 0）
```

**PASS** — 退出码 0。

### T3. HTML 可解析性（python3 html.parser）

```
$ python3 -c "import html.parser; p=html.parser.HTMLParser(); p.feed(open('docs/lecture_btree.html').read()); print('HTML parse OK')"
HTML parse OK
```

**PASS** — 无解析异常（注：html.parser 容忍部分畸形标记，此为契约指定的最低验证标准）。

### T4. 现役 API 口吻抽查（浏览器不可用，rg 替代渲染检查）

```
$ rg -c 'getBorrowed' docs/lecture_btree.html
21
$ rg -n 'getBorrowed' docs/lecture_btree.html | rg -v '已于 T-23 移除|已移除|案例复盘|设计与移除|曾是|曾通过|原 |含已移除|历史|教学参考'
```

剩余 8 处逐条人工判定：513（复盘语境）、519（移除声明）、523（带移除标注的示例代码）、565/568（契约要求原文保留的危险框）、578（基线原有代码注释，紧邻 §4.1 移除说明，非使用指南口吻）、592（「移除 getBorrowed 后的唯一读取 API」）。**无「现役 API」口吻残留。**

**PASS**

### T5. 结构完整性（锚点/TOC 一致性）

```
$ rg -n 'id="part4"|id="s41"|href="#part4"|href="#s41"' docs/lecture_btree.html
28:    <li class="part"><a href="#part4">第四部分 · 读取路径：get 与零拷贝的取舍</a></li>
29:    <li class="sub"><a href="#s41">4.1 案例复盘：getBorrowed 的设计与移除</a></li>
508:<section class="lecture" id="part4">
516:<h3 id="s41">4.1 案例复盘：getBorrowed 的设计与移除</h3>
```

TOC 与正文标题一致，锚点 id 保留无断链。**PASS**

### T6. 契约 6 项内容对照

逐条核对（详见 review.md 表格）：目录标题、案例复盘口吻 + 代码标注、危险框原文 + 补充句、散落引用过去时、总结表状态、样式沿用 — **6/6 满足**。

**PASS**

## 结论

6 项测试全部 PASS。被测提交 `be50a85` 符合 T-24 契约，验收命令 exit 0。
