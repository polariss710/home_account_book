# 家庭账本系统

纯静态家庭账本 MVP，可部署到 GitHub Pages，并使用 Supabase 存储数据。

## 功能范围

- 账户管理
- 分类管理
- 收入、支出、转账、调整流水
- 已付 / 未付状态
- 月度总览与账户余额
- 月度未净结 / 已净结
- Supabase 表名前缀：`home_`

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
