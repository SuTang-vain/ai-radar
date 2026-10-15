# AI Radar

每天 08:30 自动跑一次的 AI 动态雷达：用 `pi` headless 模式做多角度检索，产出一份**有来源、有可信度标签、去过重**的当日简报，并推到本仓库。

## 它每天产出什么

| 文件 | 内容 |
|---|---|
| `reports/YYYY-MM-DD.md` | 当日简报：今日必读 3–5 条 + 分领域动态 + 早期信号 + 抓取说明 |
| `INDEX.md` | 所有日报索引（最新在最上） |
| `THEMES.md` | 跨天主题主线（同一主题的演进合并成时间线，最多 12 条/主题） |
| `logs/YYYY-MM-DD.log` | 完整运行日志（**不入库**，`.gitignore` 忽略；保留 30 天） |

质量约定（写在 `prompt.md` 里，agent 必须遵守）：每条必须有真实来源 URL；断言打【已证实】/【厂商宣称】/【推测】标签；先读最近两份报告做去重基线；检索预算 ≤8 次 `web_search` + ≤6 次 `fetch_content`；宁少勿凑。

## 组成

```
~/z/ai-radar/
├── prompt.md        # 任务提示词（{{DATE}} 会被替换成当天日期）
├── run.sh           # 执行器：加载密钥 → 跑 pi → 校验产物 → 通知 → 提交推送 → 清理
├── selftest.sh      # 自检：把「定时任务真能跑起来」变成可机器验证的断言
├── reports/         # 日报
├── logs/            # 运行日志（未入库）
├── INDEX.md  THEMES.md
└── ~/.config/systemd/user/ai-radar.{service,timer}   # 定时器（不在此仓库内）
```

模型：默认 `kimi-coding/kimi-for-coding-highspeed`（走 Kimi Code 套餐额度，中文资讯与 `web_search` 默认路由一致）。
驱动方式：`pi --print --approve --tools read,write,edit,web_search,fetch_content,get_search_content`，工具白名单收窄以防注意力稀释。

## 手动用

```bash
./run.sh                  # 现在跑今天的
./run.sh 2026-10-01       # 回填某天（写 reports/2026-10-01.md）
AI_RADAR_MODEL=deepseek/deepseek-flash ./run.sh    # 换模型临时跑
./selftest.sh             # 自检全部断言（含定时器、密钥、z-clean 相容性）
tail -f logs/$(date +%F).log                       # 看实时日志
```

环境变量：`AI_RADAR_MODEL` / `AI_RADAR_THINKING` / `AI_RADAR_TIMEOUT`(默认1800s) / `AI_RADAR_ATTEMPTS`(默认2) / `AI_RADAR_KEEP_REPORTS`(90天) / `AI_RADAR_KEEP_LOGS`(30天)。

## 定时器

```bash
systemctl --user list-timers ai-radar.timer     # 下次触发时间
systemctl --user start ai-radar.service         # 立刻触发一次
systemctl --user status ai-radar.service        # 上次运行结果
journalctl --user -u ai-radar.service -n 50     # 日志
systemctl --user disable --now ai-radar.timer   # 停掉定时任务
```

设定：`OnCalendar=*-*-* 08:30`、`RandomizedDelaySec=600`（避开整点拥塞）、`Persistent=true`（关机错过则开机补跑）、`TimeoutStartSec=infinity`（超时由 `run.sh` 自己管）。

## 几个刻意的设计决定

1. **不纳入 chezmoi。** 这套东西要自动 commit/push 到自己的仓库，纳入 chezmoi 会让两个版本系统互相打架；`~/.config/systemd/user/ai-radar.{service,timer}` 作为非托管文件存在。`z-clean.service` 本来也不受 chezmoi 托管。
2. **`~/z/z-clean.timer` 已排除本项目。** `~/z` 每天 00:00 删除 7 天前的条目（`find ... -mtime +7 -delete`），若不排除，`README.md`、`run.sh`、`prompt.md` 7 天后就会被删掉。排除后由本项目自己的保留策略接管（日报 90 天、日志 30 天）。`selftest.sh` 第 5 组断言专门守这一点。
   - 注意：`-delete` 隐含 `-depth`，此时 GNU find 的 `-prune` 无效，所以排除只能用 `-not -path`。
3. **密钥不进 unit 文件。** systemd `EnvironmentFile=` 不接受 `export KEY=value` 前缀，而现有密钥文件 `~/.config/pi-secrets.env` 正是这种格式，因此由 `run.sh` 内部 `source` 加载（该文件里的 `EXA_API_KEY`/`JINA_API_KEY` 用于 web 抓取的兜底通道）。
4. **推送失败不算任务失败。** 日报是主要产出，git push 失败只记 WARN 并在通知里标注，避免网络抖动触发 critical 通知风暴。`GIT_TERMINAL_PROMPT=0` 保证凭据缺失时立即失败而不是挂死。
5. **重试复用同一 session。** `--session-id ai-radar-<date>`：第一次失败后重试会接着已有上下文，而不是从零重来。

## 这个仓库是公开的

日报内容（AI 行业公开信息 + 来源链接）会公开可见，`logs/` 不推送。历史提交无法撤回 —— 推送前如不想公开发布某天内容，先 `git reset` / 删除报告文件。
