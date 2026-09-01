# T-9 Review：端序统一

## Verdict
approve

## Reviewed SHA
93da04d

## 检查清单
- [x] 37 处 .big 全改为 .little
- [x] 无遗漏（grep .big = 0）
- [x] 注释同步
- [x] 读写配对
- [x] zig build test 退出 0
- [x] zig build test-btree 退出 0

## 改动范围

T-9 commit `93da04d` 仅修改 `src/btree.zig`（1 file, 38 insertions, 38 deletions）。
其中 37 行为 `.big → .little` 代码替换，1 行为注释 `big-endian → little-endian`。
未触碰 `src/format.zig`、`src/writer.zig`、`src/db.zig` 等任何其他源文件。

## 详细检查

### 1. .big 全改为 .little（37 处）

`git diff 93da04d~1..93da04d -- src/btree.zig` 显示 37 行 `-.big` / 37 行 `+.little`。
涉及函数：
- `encodeLeafPayload` — count(u16), klen(u32), vlen(u32)
- `decodeLeafPayload` — count(u16), klen(u32), vlen(u32)
- `encodeBranchPayload` — count(u16), klen(u32), child(u32)
- `decodeBranchPayload` — count(u16), klen(u32), child(u32)
- `Leaf.open`（内联 decode count）
- `Branch.open`（内联 decode count）
- `findInLeafBorrowed` — count, klen, vlen, ov_page
- `findInBranchPayload` — count, klen, child
- `findChildIdxAndOffset` — count, klen, child
- `cowBranchNoSplit` — patch child pointer
- `insertIntoLeaf` — old_count, klen, vlen, klen2, vlen2, new_count, klen, vlen, ov_page

### 2. 无遗漏

`grep -c '\.big' src/btree.zig` = **0**（无残留）。
`grep -c '\.little' src/btree.zig` = **43**（37 新改 + 6 原有溢出页号 .little）。

### 3. 注释同步

- **line 662**: `// Patch child pointer (big-endian, as encoded by encodeBranchPayload)`
  → `// Patch child pointer (little-endian, as encoded by encodeBranchPayload)` ✓
- **line 659**: `// Update page_no in header (first 4 bytes, little-endian)` — 原有 .little，无需改 ✓

无其他 `big-endian` 文字残留。

### 4. 读写配对

| 写入函数 (encode/write) | 读取函数 (decode/read) | 字段 | 端序 |
|---|---|---|---|
| encodeLeafPayload L181 | decodeLeafPayload L220 | count (u16) | .little ↔ .little ✓ |
| encodeLeafPayload L187 | decodeLeafPayload L228 | klen (u32) | .little ↔ .little ✓ |
| encodeLeafPayload L191 | decodeLeafPayload L234 | vlen (u32) | .little ↔ .little ✓ |
| encodeLeafPayload L197 | decodeLeafPayload L343 / findInLeafBorrowed L554 | ov_page (u32) | .little ↔ .little ✓ |
| encodeBranchPayload L271 | decodeBranchPayload L289 | count (u16) | .little ↔ .little ✓ |
| encodeBranchPayload L274 | decodeBranchPayload L296 | klen (u32) | .little ↔ .little ✓ |
| encodeBranchPayload L280 | decodeBranchPayload L305 | child (u32) | .little ↔ .little ✓ |
| insertIntoLeaf L857 | insertIntoLeaf L693 | new_count / old_count (u16) | .little ↔ .little ✓ |
| insertIntoLeaf L870 | insertIntoLeaf L714 | klen (u32) | .little ↔ .little ✓ |
| insertIntoLeaf L875 | insertIntoLeaf L720 | vlen (u32) | .little ↔ .little ✓ |
| insertIntoLeaf L882 | insertIntoLeaf L747 | ov_page (u32) | .little ↔ .little ✓ |
| cowBranchNoSplit L664 | findChildIdxAndOffset L633 | child (u32) | .little ↔ .little ✓ |
| cowBranchNoSplit L660 (page_no header) | format.zig L73 (readHeader) | page_no (u32) | .little ↔ .little ✓ |

所有读写对端序一致，无错配。

### 5. 未误改其他代码

- `format.zig`（页头、meta、CRC、freelist）全为 `.little`，T-9 未触碰该文件 ✓
- 6 处原有 `.little`（溢出页号写入/读取）保持不变，未被 T-9 重复修改 ✓
- CRC 计算在 `format.zig` 中使用 `.little`，与 T-9 无关 ✓

### 6. 测试验证

- `zig build test` — 退出 0，92/92 tests passed ✓
- `zig build test-btree` — 退出 0，29/29 tests passed, 4/4 steps succeeded ✓

## 问题

无。
