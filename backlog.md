# 在线计算器站点 · 开发待办清单（Backlog）

> 定时任务的工作台账。
> - 用户在聊天中报 bug / 提优化建议时，主会话负责把条目写进「待办」，一条一行，写清现象/期望和日期。
> - 定时任务每次运行按「待办」从上到下逐项处理：开发 → 本地检查 → 推送部署 → 验证线上 → 移到「已完成」并注明结果。
> - 条目完成前如果信息不足（无法复现、需求不明），保留在「待办」并标注「待用户补充：…」。
> - 「已完成」只保留最近 15 条，更早的删掉。
> - 项目背景、部署流程、关键参数一律以同目录 RUNBOOK.md 为准，动手前先读它。

## 待办

（暂无）

## 常驻检查（每次运行必做，不属于待办）

- 站点可访问性：https://xvlain.github.io/calculator/ 返回 200
- 数据库可用性：POST https://qvbywrfkpbiojncikdnw.supabase.co/rest/v1/rpc/calc_login 可达；若报「服务尚未初始化」（function 不存在），提醒用户执行 /root/userdata/workspace/在线计算器站点/calc_setup.sql
- GitHub Pages 构建状态正常（API /repos/xvlain/calculator/pages）

## 已完成

- 2026-09-05 接入 Supabase 实时后端并上线（v1.1.0）：真实账号登录、私聊即发即到、在线状态、撤回/编辑、双向加好友
