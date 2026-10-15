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
for token in '{{DATE}}' 'reports/{{DATE}}.md' 'INDEX.md' 'THEMES.md' 'web_search' '【已证实】'; do
  check "prompt.md 含 $token" grep -qF -- "$token" "$PROJECT_DIR/prompt.md"
done
echo

echo "[3] 运行前提"
check "pi 可执行" test -x "${AI_RADAR_PI_BIN:-$HOME/.local/bin/pi}"
MODEL="$(grep -oP 'AI_RADAR_MODEL:-\K[^}]+' "$PROJECT_DIR/run.sh" | head -1)"
info "run.sh 默认模型：${MODEL:-<未解析到>}"
check "模型在 pi 模型中可见（$MODEL）" bash -c "pi --list-models 2>/dev/null | grep -qF '$MODEL'"
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
  bash -c "! grep -q 'prune' '$UNIT_DIR/z-clean.service'"
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
