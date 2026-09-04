# Skill attribution 查询计划验证

基线：`494f251`。使用 Python 系统 SQLite、内存数据库、每张去重表 1000 行、1 个 skill member。SQL 直接提取生产文件中的 `skillAttributionSQL`，没有手写 SQL 替身；未访问生产库。

观察：

- 修改前：`temp_logical_events` 被扫描 4 次；`temp_lineage_events` 和 `temp_deduped_events` 多次成为 `AUTOMATIC COVERING INDEX` 构建目标。
- 修改后：`target_logical`、`lineage_winner` 显式物化；全量逻辑表、血缘表各扫描一次，最终胜者表扫描两次。自动索引仅建立在筛出的 `t` / `lw` 小集合上。
- 两者最终结果均只有 member `7` 的归属；新计划不存在在 `l` / `w` / `d` 上构建自动索引的分支。

这是查询工作形状验证，尚不是生产耗时或磁盘峰值量化。仍保留 `temp_store=FILE`。共享 SQL 决定胜者，Swift 不新增胜者选择实现。

同轮额外验证（内存 SQLite，实际生产查询文本）：

- 移除窄 `idx_session_events_host_group` 前后，全量 session SQL 均使用 `idx_session_events_host_group_covering`；尾部 role/event/file 排序仍需临时 B-tree，没有把该排序声称为已消除。作用域 session 查询也显式使用 covering 索引。
- 修改后的映射清理实际计划为 `SEARCH usage_logical_bucket_map USING COVERING INDEX ... (hostname=? AND source=? AND event_id=?)`，其列表子查询仅扫描 `temp_scope_events`。这验证了完整主键查找，未量化生产收益。
- 临时列裁剪后，用固定 seed=417 的 160 条 raw（跨文件 tier、logical/lineage/content 分组、unknown model、非空工具 JSON）直接执行 `494f251` 与当前 full/scoped 生产 SQL，逐个保留列对比全部结果：logical 20→16 列、134 行；lineage 19→13 列、123 行；deduped 19→12 列、117 行，均相等。JSON 计数仍由 raw 读取；session/project 仍由 logical 表提供。未改变分组、排序和 token 聚合表达式。

在仓库根目录复现：

```sh
python3 - <<'PY'
import sqlite3, subprocess
from pathlib import Path
path = 'Sources/AgentPulseCore/UsageLedgerStore.swift'
versions = [('before', subprocess.check_output(['git', 'show', '494f251:' + path], text=True)),
            ('after', Path(path).read_text())]
for label, code in versions:
    sql = code[code.index('    private static func skillAttributionSQL'):].split('"""', 2)[1]
    sql = sql.replace(r'\(bucketMs)', '1800000')
    db = sqlite3.connect(':memory:')
    db.execute('CREATE TEMP TABLE temp_skill_members(source TEXT,event_id TEXT,PRIMARY KEY(source,event_id))')
    for table in ['temp_logical_events', 'temp_lineage_events', 'temp_deduped_events']:
        db.execute(f'CREATE TEMP TABLE {table}(source TEXT,event_id TEXT,lineage_fingerprint TEXT,codex_dedup_key TEXT,model TEXT,project TEXT,timestamp_ms INTEGER)')
        db.executemany(f'INSERT INTO {table} VALUES(?,?,?,?,?,?,?)',
                       [('codex', str(i), '', '', 'm', 'p', i) for i in range(1000)])
    db.execute("INSERT INTO temp_skill_members VALUES('codex','7')")
    plan = [row[3] for row in db.execute('EXPLAIN QUERY PLAN ' + sql)]
    print(label, plan)
    db.executescript(sql)
    rows = db.execute('SELECT * FROM temp_skill_attribution').fetchall()
    assert len(rows) == 1 and rows[0][1] == '7', rows
    if label == 'after':
        assert not any(('SEARCH ' + alias + ' USING AUTOMATIC') in row
                       for alias in ['l', 'w', 'd'] for row in plan), plan
print('PASS')
PY
```
