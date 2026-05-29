# 家庭账本系统

纯静态家庭账本 MVP，可部署到 GitHub Pages，并使用 Supabase 存储数据。

## 功能范围

- 阶段一聚焦日元固定收支。
- 固定模板支持长期固定和短期固定。
- 本月固定项由 Supabase RPC 生成，前端只展示结果。
- 短期固定模板按开始月份和总期数判断当前账期是否可生成。
- 使用中但已到期的短期模板只提示，不自动停止生成。
- Supabase 表名前缀：`home_`。

## 业务规则备忘

### 固定模板状态

当前使用 `is_active` 表示是否继续生成：

- `true`：使用中。
- `false`：停止生成，表示暂时不生成，但允许恢复。

后续如果停止生成的数据变多，考虑把 `is_active` 升级为更明确的 `status`：

- `active`：使用中。
- `paused`：暂停生成，可恢复。
- `archived`：确认已结束，默认隐藏。

误建模板如果从未生成过月度记录，后续可以允许真删除。已经生成过月度记录的模板不要删除历史，只改变未来生成规则。

### 总览设计方向

当前总览仍是实验显示。后续重做时应区分“计划”和“实际”：

- 预计固定收入。
- 已收固定收入。
- 未收固定收入。
- 预计固定支出。
- 已付固定支出。
- 未付固定支出。
- 固定收支预计盈亏。
- 固定收支实际盈亏。
- 当前固定资金余额或月末预计余额。

总览不应该只显示单一收入、支出、余额。未付和未收属于计划，已付和已收才进入实际结算视角。

## Supabase

先在 Supabase SQL Editor 执行：

```sql
-- 见 supabase-schema.sql
```

当前前端默认连接到 `polariss710's Cash System`，只访问 `home_` 前缀表。

## GitHub Pages

部署方式：

1. 将本目录推送到 GitHub repository。
2. 在 GitHub repository 中打开 `Settings -> Pages`。
3. Source 选择 `Deploy from a branch`。
4. Branch 选择 `main`，目录选择 `/root`。
5. 保存后访问 GitHub Pages 地址。
