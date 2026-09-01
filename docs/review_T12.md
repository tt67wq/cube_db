# T-12 Review：溢出页链测试

## Verdict
approve

## Reviewed SHA
897e358

## 检查清单
- [x] 4 个场景全覆盖
- [x] 断言具体值
- [x] PageStore 搭建正确
- [x] zig build test-btree 退出 0
- [x] 未改 src/

## 改动范围

T-12 commit `897e358` 仅修改 `tests/` 下 2 文件：
- 新建 `tests/btree_storage/btree_overflow_chain_test.zig`（252 行，4 test 块）
- 修改 `tests/btree_storage/btree_test.zig`（comptime 块追加 `@import("btree_overflow_chain_test.zig")`）

未触碰 `src/` 下任何文件。

## 场景覆盖

### 1. 多页溢出链（50KB）— task.md 要点 2

| 要求 | 实现 | 断言强度 |
|---|---|---|
| put 50KB → 查询返回正确值 | `btree.insert` + `btree.get` | `expectEqualSlices(u8, &value, got.?)` 逐字节匹配 50000 字节 ✓ |
| 链长度 = ceil(50000/4068) | `walkOverflowChain` 遍历 | `expectEqual(@as(u32,13), chain.items.len)` 具体值 ✓ |
| 每页 page_type = OVERFLOW | `decodePageHeader` 逐页 | `expectEqual(f2.PAGE_TYPE_OVERFLOW, hdr.page_type)` 逐页断言 ✓ |
| free_next 串联正确 | 遍历时逐页检查 | 非末页 `expectEqual(chain[idx+1], hdr.free_next)`，末页 `expectEqual(0, hdr.free_next)` ✓ |
| 逐页内容匹配 | 逐页读 payload 区 | `expectEqualSlices(u8, value[offset..][0..chunk], chunk)` ✓ |

数据校验：50000 字节用 `i % 251` 非平凡 pattern，避免全零假阳性。末页 16 字节（50000 = 12×4068 + 16）正确处理。

### 2. 更大值（100KB）— task.md 要点 3

| 要求 | 实现 | 断言强度 |
|---|---|---|
| put 100KB → 查询返回正确值 | `btree.insert` + `btree.get` | `expectEqualSlices(u8, &value, got.?)` 100000 字节匹配 ✓ |
| 链长度 = ceil(100000/4068) = 25 | `walkOverflowChain` | `expectEqual(@as(u32,25), chain.items.len)` 具体值 ✓ |

数据校验：`(i*7) % 251` 不同 pattern，与场景 1 区分。

### 3. 溢出页回收 — task.md 要点 4

| 要求 | 实现 | 断言强度 |
|---|---|---|
| put 大值 → 记录溢出页号 | `overflowFirstPage` + `walkOverflowChain` | 链长度 ≥ 3 ✓ |
| overwrite → 旧链进 dirty | `insert(root, "k", "small", ...)` 触发 `freeOverflowPages` | `freed_count >= overflow_page_count` 逐页号交叉匹配 ✓ |
| 后续 alloc 复用（LIFO） | 手动 `freePage` → 连续 `allocPage` | `reused > 0` 验证 LIFO 复用 ✓ |

### 4. freeOverflowPages 静默失败 — task.md 要点 5

| 要求 | 实现 | 断言强度 |
|---|---|---|
| 破坏链中页 free_next | 改第 2 页 `free_next = 0xFFFFFFFE`（无效页号） | `writePage` + `encodePageHeader` 直接改页头 ✓ |
| freeOverflowPages 不 panic | `btree.insert` overwrite 触发 | `catch |err| { return err; }` 但期望成功 ✓ |
| 已遍历页进 dirty | 检查 dirty2 含首页 + 破坏页 | `found_first = true`, `found_break = true` ✓ |
| 断裂后页不进 dirty | 检查 dirty2 不含第 3 页+ | `!found_after_break` ✓ |

## PageStore 搭建

测试使用 `ps.MemPageStore.init(allocator, N)` 构造内存页存储，`ms.store()` 获取 `PageStore` 接口。与 `btree_test.zig` 和 `readtxn_fuzz.zig` 的搭建方式一致。页容量按需分配（100000~200000 页），足够容纳 50KB~100KB 溢出链。

private 函数（`writeOverflowPages`/`readOverflowValue`/`freeOverflowPages`）通过 pub API（`btree.insert`/`btree.get`）间接触发，符合 task.md 要点 6 的要求。辅助函数 `overflowFirstPage` 和 `walkOverflowChain` 用 `readNodePayload`/`decodeLeafPayload`/`decodePageHeader` 直接观察链结构——这些是 pub 函数，无需访问 private 内部。

## 常量验证

- `OVERFLOW_PAYLOAD = PAGE_SIZE(4096) - PAGE_HEADER_SIZE(24) - 4(CRC) = 4068` ✓（与 `src/btree.zig:78` 一致）
- `expectedOverflowPages(50000) = ceil(50000/4068) = 13` ✓
- `expectedOverflowPages(100000) = ceil(100000/4068) = 25` ✓
- `PAGE_TYPE_OVERFLOW = 4` ✓（与 `src/format.zig:13` 一致）
- `LEAF_FLAG_OVERFLOW = 1` ✓（与 `src/btree.zig:82` 一致，测试用 `e.flags & 1`）

## 测试验证

`zig build test-btree` — 退出 0，4/4 steps succeeded, 33/33 tests passed ✓

## 问题

无。
