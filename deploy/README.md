# 部署到 Linux 服务器

主仓库默认按「本机 + systemd --user」设计。这份文档记录在**一台境内云服务器**上从零跑通的完整路径（Ubuntu 24.04 / root / cron），包括境内网络需要额外处理的三件事。

实测环境：

```
Ubuntu 24.04.2 LTS · x86_64 · 2C2G · Asia/Shanghai
node v22.23.4 · npm 10.9.9 · git 2.43 · python3 3.12
京东云，无公网代理
```

## 1. 装 pi 与扩展

pi 是标准 npm 包，要求 Node ≥ 22.19：

```bash
node -v                              # 必须 ≥ 22.19
npm i -g @earendil-works/pi-coding-agent
pi --version
```

装检索扩展（二选一，取决于你用哪条搜索通道）：

```bash
pi install npm:pi-web-access      # 零配置走 Exa MCP；也可显式指定 deepseek 等 provider
# pi install npm:pi-web-search    # 走 DeepSeek 原生 Search API，复用 DeepSeek key
```

> 建议**锁版本**。扩展在升级时可能被替换（`pi-web-search` ↔ `pi-web-access`），
> 行为会跟着变，报告质量也会悄悄漂移。

## 2. 配模型凭据

pi 读取 `~/.pi/agent/auth.json`：

```bash
mkdir -p ~/.pi/agent
cat > ~/.pi/agent/auth.json <<'EOF'
{"deepseek": {"type": "api_key", "key": "sk-..."}}
EOF
chmod 600 ~/.pi/agent/auth.json
```

也可以不写文件，靠环境变量 `DEEPSEEK_API_KEY`（cron 里需要显式传入）。

## 3. 部署代码

```bash
git clone <this-repo> /opt/ai-radar
cd /opt/ai-radar
cp config.env.example config.env 2>/dev/null || touch config.env
chmod 600 config.env
```

`config.env` 至少需要：

```
FEISHU_WEBHOOK_URL=https://open.feishu.cn/open-apis/bot/v2/hook/...
REPORT_BASE_URL=https://github.com/<owner>/<repo>/blob/main
```

## 4. 境内网络的三处适配

### 4.1 HuggingFace 走镜像

境内服务器直连 `huggingface.co` 是 000。`fetch.sh` 支持把 HF 请求重写到镜像（请求走镜像，**记账仍用原始 URL**，否则报告里的链接和一手取证的 URL 池对不上）：

```
HF_MIRROR=https://hf-mirror.com
```

`https://hf-mirror.com/api/models?sort=trendingScore&direction=-1&limit=10` 返回的数据与主站一致（trendingScore / likes / downloads）。

### 4.2 GitHub 推送走 SSH over 443

境内 `github.com:443` 不通，但 `api.github.com` 和 `ssh.github.com:443` 通。

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519_github -N ""
cat ~/.ssh/id_ed25519_github.pub      # 加到 GitHub → Settings → SSH and GPG keys

cat > ~/.ssh/config <<'EOF'
Host github.com
  HostName ssh.github.com
  Port 443
  User git
  IdentityFile ~/.ssh/id_ed25519_github
  IdentitiesOnly yes
EOF
chmod 600 ~/.ssh/config

ssh -T git@github.com     # 应返回 Hi <user>!
```

然后 `git remote set-url origin git@github.com:<owner>/<repo>.git`。

### 4.3 抓取走代理（可选，但直接影响报告质量）

`fetch.sh` 是「先直连，失败才走 `FETCH_PROXY`」的两级策略，所以只需要给一个本地端口：

```
FETCH_PROXY=http://127.0.0.1:7897
```

代理内核可以是任意支持 HTTP 的（clash/mihomo 均可）。**装的时候注意关掉 TUN 模式**：

```yaml
tun:
  enable: false        # ← 必须 false
```

原因是 TUN 的 `auto-route` 会把所有流量（含 `ssh.github.com:443`）劫持进 fake-ip（`198.18.x.x`），
git push 会报 `Connection closed by 198.18.0.25 port 443`。只需要 mixed-port 给 `fetch.sh` 用就够了。

实测对比（同一台机器、同一份 prompt）：

| | 无代理 | 有代理 |
|---|---|---|
| 一手来源 | 5 条 | 16 条 |
| 一手取证 | 2/2 | 11/11 |

## 5. 定时：cron

```bash
crontab -e
```

```
30 8 * * * cd /opt/ai-radar && PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin ./run.sh >> /opt/ai-radar/logs/cron.out.log 2>&1
```

三点注意：

- **必须显式给 PATH**：cron 不读 `.bashrc`/`.profile`，默认 PATH 里没有 `/usr/local/bin`，会找不到 `pi`。
- **`run.sh` 内部已经 `cd` 到项目目录**，但 cron 行里再写一次无害，便于排查。
- 时区用系统默认（`timedatectl` 确认是 `Asia/Shanghai`），cron 用的是本地时间。

验证（不等到 08:30）：

```bash
env -i HOME=/root PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin \
  sh -c 'cd /opt/ai-radar && ./fetch.sh https://huggingface.co/api/models?limit=1 60'
```

## 6. 定时：systemd --user（本机/有图形会话的机器）

```bash
mkdir -p ~/.config/systemd/user
cp deploy/ai-radar.service deploy/ai-radar.timer ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now ai-radar.timer
systemctl --user list-timers ai-radar.timer
```

## 7. 首次验证

```bash
cd /opt/ai-radar
./run.sh                    # 完整跑一次（约 6–10 分钟）
tail -f logs/$(date +%F).log
```

跑完检查：

- `reports/<date>.md` 存在且 > 10KB
- 日志里有 `运行器取证：web_search N 次 / fetch_content M 次`
- 报告头部有「信息来源（运行器写入）」
- 配了飞书的话，群里收到卡片

## 常见失败

| 现象 | 原因 |
|---|---|
| `Insufficient Balance` | 账户余额不足。`run.sh` 会立即 `exit 3`，充值后手动跑 `./run.sh <date>` 补 |
| `git push` 报 `Connection closed by 198.18.x.x` | 代理 TUN 劫持了 SSH，关掉 `tun.enable` |
| `pi: command not found`（cron） | cron 的 PATH 没包含 pi 所在目录 |
| 一手来源只有个位数 | 没有代理，境外官方站全抓不到；或 `HF_MIRROR` 未配 |
| 报告里 LMArena / GitHub Trending 一节为空 | 这两个站是 JS 渲染或 Cloudflare 403，`fetch.sh` 只能拿到导航壳，属预期 |
