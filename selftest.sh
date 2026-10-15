#!/usr/bin/env bash
# AI Radar 自检：把「定时任务是否真能跑起来」变成可机器验证的断言。
#   ./selftest.sh        # 全部检查，PASS/FAIL 汇总，任一 FAIL 则退出码 1
set -uo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
UNIT_DIR="$HOME/.config/systemd/user"
PASS=0; FAIL=0
ok()   { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
bad()  { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
info() { printf '  \033[2m----\033[0m %s\n' "$1"; }
check() { # 描述, 命令…（退出 0 记 PASS）
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

echo "AI Radar 自检 — $PROJECT_DIR"
echo

echo "[1] 项目文件"
for f in prompt.md run.sh selftest.sh README.md INDEX.md THEMES.md; do
  check "$f 存在且非空" test -s "$PROJECT_DIR/$f"
done
check "run.sh 可执行" test -x "$PROJECT_DIR/run.sh"
check "run.sh 语法正确（bash -n）" bash -n "$PROJECT_DIR/run.sh"
check "selftest.sh 语法正确（bash -n）" bash -n "$PROJECT_DIR/selftest.sh"
check "reports/ 可写" test -w "$PROJECT_DIR/reports"
check "logs/ 可写" test -w "$PROJECT_DIR/logs"
echo

echo "[2] 提示词契约（prompt.md 必须约束住产出路径）"
for token in '{{DATE}}' '{{WEEK_START}}' 'reports/{{DATE}}.md' 'INDEX.md' 'THEMES.md' 'web_search' '【已证实】' '本轮实际' '最近一周产品情况' '热度榜与风评' '趋势解读' '至少覆盖 2 个不同来源' 'provider: "exa"' '【一手】' '【社媒线索】' '一手来源核查'; do
  check "prompt.md 含 $token" grep -qF -- "$token" "$PROJECT_DIR/prompt.md"
done
echo

echo "[2b] 执行器护栏（防“零检索凭记忆交作业”与上下文复用）"
check "session 收在项目内（logs/sessions）" grep -qF 'SESSION_DIR="$LOG_DIR/sessions"' "$PROJECT_DIR/run.sh"
check "每次调用生成独立 session id" grep -qF 'SESSION_ID="ai-radar-$DATE-$(date +%H%M%S)"' "$PROJECT_DIR/run.sh"
check "run.sh 传了 --session-dir" grep -qF -- '--session-dir "$SESSION_DIR"' "$PROJECT_DIR/run.sh"
check "存在真实检索次数护栏" grep -qF 'AI_RADAR_MIN_SEARCHES' "$PROJECT_DIR/run.sh"
check "窗口起点 {{WEEK_START}} 会被渲染" grep -qF '{{WEEK_START}}' "$PROJECT_DIR/run.sh"
check "周度窗口为滚动 7 天" grep -qF 'date -d "$DATE -6 days"' "$PROJECT_DIR/run.sh"
check "存在报告必备章节校验" grep -qF 'AI_RADAR_REQUIRE' "$PROJECT_DIR/run.sh"
check "真实调用次数会追写进报告（运行器取证）" grep -qF '运行器取证' "$PROJECT_DIR/run.sh"
check "超预算会告警" grep -qF '超出抓取预算' "$PROJECT_DIR/run.sh"
check "引文溯源已机器化" grep -qF '引文溯源' "$PROJECT_DIR/run.sh"
check "URL 归一化函数存在" grep -qF 'norm_url()' "$PROJECT_DIR/run.sh"
check "溯源严格模式可开关" grep -qF 'AI_RADAR_CITATION_STRICT' "$PROJECT_DIR/run.sh"
check "报告头部会写入来源披露" grep -qF '信息来源（运行器写入）' "$PROJECT_DIR/run.sh"
check "会统计 exa 升级次数" grep -qF 'exa_upgrades' "$PROJECT_DIR/run.sh"
check "会检测社交平台引用" grep -qF 'social_cites' "$PROJECT_DIR/run.sh"
check "会统计来源层级标注数" grep -qF 'tier_first' "$PROJECT_DIR/run.sh"
check "必备章节含《一手来源核查》" grep -qF '一手来源核查' "$PROJECT_DIR/run.sh"
check "预算上限与提示词口径同源可配" grep -qF 'AI_RADAR_BUDGET_FETCH' "$PROJECT_DIR/run.sh"
check "无效报告会触发重试" grep -qF '报告可能凭空生成' "$PROJECT_DIR/run.sh"
check "sessions 目录也被保留策略清理" grep -qF "prune \"\$SESSION_DIR\"" "$PROJECT_DIR/run.sh"
echo

echo "[3] 运行前提"
check "pi 可执行" test -x "${AI_RADAR_PI_BIN:-$HOME/.local/bin/pi}"
MODEL="$(grep -oP 'AI_RADAR_MODEL:-\K[^}]+' "$PROJECT_DIR/run.sh" | head -1)"
info "run.sh 默认模型：${MODEL:-<未解析到>}"
check "模型在 pi 模型中可见（$MODEL）" \
  bash -c "pi --list-models 2>/dev/null | awk '{print \$1\"/\"\$2}' | grep -qxF '$MODEL'"
check "密钥文件 ~/.config/pi-secrets.env 存在" test -r "$HOME/.config/pi-secrets.env"
check "密钥文件含 EXA_API_KEY" grep -q 'EXA_API_KEY=' "$HOME/.config/pi-secrets.env"
check "密钥文件含 JINA_API_KEY" grep -q 'JINA_API_KEY=' "$HOME/.config/pi-secrets.env"
check "pi 凭据 auth.json 存在" test -r "$HOME/.pi/agent/auth.json"
check "pi-web-access 已安装（提供 web_search）" bash -c "pi list 2>/dev/null | grep -q 'pi-web-access'"
echo

echo "[4] 定时任务"
check "ai-radar.service 存在" test -f "$UNIT_DIR/ai-radar.service"
check "ai-radar.timer 存在" test -f "$UNIT_DIR/ai-radar.timer"
check "ai-radar.timer 已 enable" systemctl --user is-enabled --quiet ai-radar.timer
check "ai-radar.timer 处于 active" systemctl --user is-active --quiet ai-radar.timer
check "timer 配置为 08:30" grep -q 'OnCalendar=.*08:30' "$UNIT_DIR/ai-radar.timer"
check "timer 具备错过后补跑（Persistent=true）" grep -q '^Persistent=true' "$UNIT_DIR/ai-radar.timer"
check "service 显式加载密钥文件" grep -q 'pi-secrets.env' "$UNIT_DIR/ai-radar.service"
echo

echo "[5] 与 ~/z 清理策略的相容性（最容易被踩的坑）"
check "z-clean.service 已排除本项目路径" grep -qF "$PROJECT_DIR" "$UNIT_DIR/z-clean.service"
check "z-clean.service 未混用 -prune 与 -delete（GNU find 不兼容）" \
  bash -c "! grep '^ExecStart=' '$UNIT_DIR/z-clean.service' | grep -q prune"
info "z-clean 现有规则：$(grep -oP '^ExecStart=.*' "$UNIT_DIR/z-clean.service" | head -1)"
echo

echo "[6] 桌面通知可达性（从 systemd 服务环境实测）"
check "notify-send 存在" command -v notify-send
check "systemd 服务环境里有 DBus 会话总线" \
  bash -c "systemd-run --user --wait --pipe -q /usr/bin/env 2>/dev/null | grep -q '^DBUS_SESSION_BUS_ADDRESS='"
check "systemd 服务环境里有图形显示变量" \
  bash -c "systemd-run --user --wait --pipe -q /usr/bin/env 2>/dev/null | grep -qE '^(DISPLAY|WAYLAND_DISPLAY)='"
echo

echo "[7] 版本管理（GitHub 公开仓库，非 chezmoi）"
check "项目是 git 仓库" git -C "$PROJECT_DIR" rev-parse --git-dir
check "已配置 origin 远端" git -C "$PROJECT_DIR" remote get-url origin
check "origin 指向 SuTang-vain/ai-radar" \
  bash -c "git -C '$PROJECT_DIR' remote get-url origin | grep -q 'SuTang-vain/ai-radar'"
check ".gitignore 忽略了 logs/" bash -c "git -C '$PROJECT_DIR' check-ignore -q logs/probe.log"
check ".gitignore 同时覆盖 logs/sessions/" bash -c "git -C '$PROJECT_DIR' check-ignore -q logs/sessions/probe.jsonl"
check "logs/ 未被跟踪" bash -c "! git -C '$PROJECT_DIR' ls-files --error-unmatch logs/ 2>/dev/null | grep -q ."
check "git 凭据助手已配置为 gh" \
  bash -c "git config --global --get-regexp '^credential\.https://github\.com\.helper' | grep -q 'gh auth git-credential'"
check "gh 在 systemd 服务环境里可用（keyring 已解锁）" \
  bash -c "systemd-run --user --wait --pipe -q \"\$HOME/.local/bin/gh\" auth status >/dev/null 2>&1"
check "远端仓库可达" bash -c "timeout 30 gh repo view SuTang-vain/ai-radar >/dev/null 2>&1"
info "远端：$(git -C "$PROJECT_DIR" remote get-url origin 2>/dev/null || echo '<无>')"
info "未推送提交：$(git -C "$PROJECT_DIR" rev-list --count origin/main..HEAD 2>/dev/null || echo '?') 个"
check "service 指定的模型与 run.sh 默认一致" \
  bash -c "[ \"\$(grep -oP 'AI_RADAR_MODEL:\\-\\K[^}]+' '$PROJECT_DIR/run.sh' | head -1)\" = \"\$(grep -oP 'Environment=AI_RADAR_MODEL=\\K.*' '$UNIT_DIR/ai-radar.service')\" ]"
echo

echo "[8] 运行留痕"
if ls "$PROJECT_DIR"/reports/*.md >/dev/null 2>&1; then
  info "已有报告 $(ls "$PROJECT_DIR"/reports/*.md | wc -l) 份，最新：$(ls -t "$PROJECT_DIR"/reports/*.md | head -1)"
  latest="$(ls -t "$PROJECT_DIR"/reports/*.md | head -1)"
  d="$(basename "$latest" .md)"
  sess="$(ls -t "$PROJECT_DIR"/logs/sessions/*_"ai-radar-$d-"*.jsonl 2>/dev/null | head -1)"
  if [ -n "$sess" ]; then
    n=$(grep -o '"type":"toolCall","id":"[^"]*","name":"web_search"' "$sess" | wc -l)
    info "最新报告的 session 里记录到真实 web_search $n 次（$(basename "$sess")）"
    if [ "$n" -ge 2 ]; then ok "最新报告有真实检索取证（≥2 次）"; else bad "最新报告缺少真实检索取证（仅 $n 次）"; fi
  else
    info "最新报告没有对应 session 文件（可能产生于 session-dir 改造之前）"
  fi
  # 对产物本身做结构校验：必备章节是否真的写进了报告
  miss=""
  for t in 今日必读 最近一周产品情况 热度榜与风评 一手来源核查 抓取说明; do grep -qF -- "$t" "$latest" || miss="$miss$t "; done
  if [ -z "$miss" ]; then ok "最新报告包含五个必备章节"; else bad "最新报告缺少章节：$miss"; fi
  check "周度清单写明了滚动窗口区间" grep -qE '^## 最近一周产品情况（[0-9]{4}-[0-9]{2}-[0-9]{2} ~ [0-9]{4}-[0-9]{2}-[0-9]{2}）' "$latest"
  if grep -qE '^\|.*上次记录|^\| 榜单' "$latest"; then ok "含《热度榜与风评》可比快照表"; else info "未找到快照表（首日无往期记录时属正常）"; fi
  if grep -qF '运行器取证' "$latest"; then ok "报告含运行器取证的真实调用次数"; else bad "报告缺少运行器取证行"; fi
  if grep -qF '信息来源（运行器写入）' "$latest"; then ok "报告头部含来源通道披露"; else bad "报告头部缺少来源披露"; fi
else
  info "尚无报告（还没跑过，或已被保留策略清理）"
fi
if command -v systemctl >/dev/null && systemctl --user is-active --quiet ai-radar.timer; then
  info "下次触发：$(systemctl --user list-timers ai-radar.timer --no-pager 2>/dev/null | sed -n '2p' | awk '{print $1, $2, $3}')"
fi
echo

printf '结果：\033[32m%d PASS\033[0m / ' "$PASS"
if [ "$FAIL" -gt 0 ]; then printf '\033[31m%d FAIL\033[0m\n' "$FAIL"; exit 1; fi
printf '0 FAIL\n'
exit 0
