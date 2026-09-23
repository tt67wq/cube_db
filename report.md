# T-64 Report — T-53-1 评审 3 NB 集合（usage 文档 / 单撕+单零形态专测 / R3 收紧）

- **分支**: `t64-nbs`（基于 main `7b9288c`）
- **结论**: **GREEN** —— check.sh 5/5 PASS（gate rc=0，含 Linux 容器冒烟）
- **改动面**: `docs/usage.md`（§4.1 + 错误表两行）+ `tests/txn_writer_db/t535_torn_meta_test.zig`（新增 t5/t6/t7 + 2 个构造 helper，t1-t4 零改动）+ `src/file_page_store.zig`（R3 校验，白名单内唯一 src 文件）

## 1. usage.md 新错误文档（NB-1）

- 错误表（§4）补两行：`InvalidMeta`（CRC 合法但不被识别 / 槽位伪造）与
  `TornMetaNoFreshEvidence`（双槽均非零且皆不可读——单次崩溃只可能撕一槽，
  双撕只能是外源损坏；拒绝当 fresh 以保护可能已提交的数据页）。
- 新增 **§4.1 打开失败处置**：两错误的形态区分 + 用户处置四步——确认无并行
  写者（`InvalidMeta` 最常见原因）→ **先备份原文件** → 优先从备份恢复 →
  确认弃数据才重建，且有条件先 `cube_check scrub`（链接 docs/cube-check.md）
  诊断，勿盲目 force 重建覆盖现场。
- 体例沿用既有 §4 错误表 + 小节结构；diff 仅 docs/usage.md。

## 2. 形态专测 t5/t6（NB-2，只新增不改 t1-t4）

**t5（放行分支直断言）**：构造「恰一槽非零 torn + 另一槽全零」（单提交库 →
撕 META_PAGE_0 一字节 + 整页清零 META_PAGE_1；构造即 T-53-1 已裁决的
impossibility 残余指纹，等价 mid-first-commit 形态）：

- `fps.next_free == ps.FIRST_DATA_PAGE`（**next_free 语义**：fresh 判定 →
  分配指针在数据区起点，不接续已消失的旧提交）
- 放行后可写：`putDirect` + `get` 正常
- **无复活**：entryCount==0，被撕槽里的旧提交数据不出现
- 放行语义跨 reopen 保持（构造即双槽协议下的合法恢复态）

**t6（拒绝路径对照，与 t5 一字节之差）**：同构造但 slot1 撕坏而非清零 →
双槽均非零且皆不可读 → 必须拒绝。锁死「t5 的放行不是把门整个拆了」。

## 3. R3 收紧（TDD RED→GREEN）

**手搓 meta 站点 grep 结论**（任务要求先查）：`writeMetaPage`/`META_PAGE_*`
手搓站点 7 处——open_meta_guard(:109-148)、format_test(:209-292)、
crc_regression(:57/:216)、meta_corrupt_fuzz(:28)、freelist_persist(:226)、
range_tombstone_format、page_store_test——**全部槽号与写入 index 匹配**
（format_test/page_store_test 是纯格式层/内存层，不过 FPS vtReadMeta；
过 FPS 的站点 idx 均与槽一致）→ 判定不受影响。

**RED（t7 新增）**：`buildDb(1)` → `copySlotPage(META_PAGE_0 → META_PAGE_1)`
（字节级把 meta0 复制进 meta1 槽：CRC 是对整页算的，搬页不改字节 → CRC 合法、
payload 自洽）。修前 `Db.open` 接受（t7 RED 实测：`RED: forged slot-swap meta
(page_no mismatch) was accepted`）。

**GREEN**：`src/file_page_store.zig` `vtReadMeta` 顶部（memcpy 重同步之后、
readMetaPage 与 torn 门之前——必须在 `if (r) |meta| return meta` 快捷返回之前，
否则合法槽会短路掉伪造槽的检查）新增：

```zig
fn slotPageNoMismatch(page: *const [PAGE_SIZE]u8, expected: u32) bool {
    if (!f2.verifyPageChecksum(page)) return false; // torn/zero → 既有门处理
    const hdr = f2.decodePageHeader(page[0..f2.PAGE_HEADER_SIZE]);
    return hdr.page_type == f2.PAGE_TYPE_META and hdr.page_no != expected;
}
// vtReadMeta: 任一槽 CRC 合法 META 页 page_no ≠ 槽位页号 → error.InvalidMeta
```

错误族归属：与 T-53 的「CRC 合法但不认识 → InvalidMeta」同族（信任链同型号
松动点），复用既有错误与传播路径（`Db.open` 的 `try store.readMeta()`）。
torn/zero 页 checksum 先行短路，与 T-53-1 双门零交互。

**回归证据**：t535 全家（t1-t7）rc=0；open_meta_guard / crc_regression /
meta_corrupt_fuzz / freelist_persist / crash_insertbatch_pb 全 rc=0。
（`-Dfilter=format` 的红是 T-39 RED-by-design 用例被子串误抓，BASE 上同样红，
非本次改动——已 stash 对照实证。）

## 门逐条（bash check.sh <worktree>）

| 门 | 结果 |
|---|---|
| gate1 t535（含 t5/t6/R3）×3 无 flake | PASS |
| gate2 src/ 白名单（仅 file_page_store.zig） | PASS |
| gate3 usage.md touched | PASS |
| gate4 macOS 全量 rc=0 fc=0 | PASS |
| gate5 Linux 容器（t62-debian-arm64，git archive 原生 fs）：t535 + crash_insertbatch_pb | PASS |

RESULT: PASS (5/5)，exit 0。

## 备注

- R3 只收紧 FPS 读门（`vtReadMeta`）；`FilePageStore.init` 保持非失败语义不变
  （诊断工具仍可打开坏文件，硬门在 Db.open——与 T-53 既有分层一致）。
  `MemPageStore` 不在白名单且无此攻击面（内存层，无跨进程伪造场景）。
- `readMetaPageSingle`（单页读，无槽位上下文）不改——crc_regression 等直接
  调用者语义不变。
