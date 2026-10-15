#!/usr/bin/env bash
# AI Radar — 每日 AI 动态扫描的执行器（由 ai-radar.timer 调用，也可手动跑）
#
#   ./run.sh              # 跑今天
#   ./run.sh 2026-10-01   # 回填某天（报告会写到 reports/2026-10-01.md）
#
# 可用环境变量覆盖：AI_RADAR_MODEL / AI_RADAR_THINKING / AI_RADAR_TIMEOUT
#                  AI_RADAR_ATTEMPTS / AI_RADAR_KEEP_REPORTS / AI_RADAR_KEEP_LOGS
set -uo pipefail
export GIT_TERMINAL_PROMPT=0   # 凭据缺失时立即失败，别在无人值守时挂死等输入

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR" || exit 1

DATE="${1:-$(date +%F)}"
MODEL="${AI_RADAR_MODEL:-kimi-coding/kimi-for-coding-highspeed}"
THINKING="${AI_RADAR_THINKING:-high}"
RUN_TIMEOUT="${AI_RADAR_TIMEOUT:-1800}"        # 单次尝试上限（秒）
ATTEMPTS="${AI_RADAR_ATTEMPTS:-2}"
MIN_REPORT_BYTES=400                            # 低于此字节数视为无效报告
MIN_SEARCHES="${AI_RADAR_MIN_SEARCHES:-2}"         # 本轮至少要有这么多次真实 web_search
KEEP_REPORT_DAYS="${AI_RADAR_KEEP_REPORTS:-90}"
KEEP_LOG_DAYS="${AI_RADAR_KEEP_LOGS:-30}"

LOG_DIR="$PROJECT_DIR/logs"
SESSION_DIR="$LOG_DIR/sessions"          # session 收进项目内：随日志一起保留/清理，不入库
REPORT="$PROJECT_DIR/reports/$DATE.md"
LOG="$LOG_DIR/$DATE.log"
# 每次调用用独立的 session id：避免重跑同一天时复用旧上下文“凭记忆”交作业
# （同一调用内的重试仍然复用，保留续跑能力）
SESSION_ID="ai-radar-$DATE-$(date +%H%M%S)"
PI_BIN="${AI_RADAR_PI_BIN:-$HOME/.local/bin/pi}"

mkdir -p "$LOG_DIR" "$SESSION_DIR" "$PROJECT_DIR/reports"
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$LOG"; }

# systemd 服务不读 .bashrc，密钥在这里显式加载
if [ -r "$HOME/.config/pi-secrets.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$HOME/.config/pi-secrets.env"
  set +a
else
  log "WARN: ~/.config/pi-secrets.env 缺失，web 抓取可能降级"
fi

notify() { # title, body, urgency
  timeout 15 notify-send --app-name="AI Radar" --icon=dialog-information \
    -u "${3:-normal}" "$1" "$2" >/dev/null 2>&1 || log "WARN: notify-send 失败（无图形会话？）"
}

# 从日报里抠出前 N 条「今日必读」的加粗结论，用于通知正文
headlines() { # N
  awk -v limit="$1" '
    /^## / { insec = ($0 ~ /^## 今日必读/) }
    insec && /^- / {
      if (match($0, /\*\*[^*]+\*\*/)) { print "• " substr($0, RSTART + 2, RLENGTH - 4) }
      else { s = substr($0, 3); print "• " (length(s) > 90 ? substr(s, 1, 90) "…" : s) }
      n++; if (n >= limit) exit
    }' "$REPORT" 2>/dev/null
}

[ -f "$PROJECT_DIR/prompt.md" ] || { log "FATAL: prompt.md 不存在"; notify "AI Radar 配置错误" "找不到 prompt.md" critical; exit 2; }
PROMPT="$(sed "s/{{DATE}}/$DATE/g" "$PROJECT_DIR/prompt.md")"
[ -n "$PROMPT" ] || { log "FATAL: prompt 渲染为空"; exit 2; }

log "===== ai-radar $DATE 开始（model=$MODEL, thinking=$THINKING, attempts=$ATTEMPTS）====="

status="fail"; attempt=0
while [ "$attempt" -lt "$ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  log "-- attempt $attempt/$ATTEMPTS --"
  rm -f "$REPORT"   # 清掉旧文件，避免残留报告冒充本次成功
  timeout "$RUN_TIMEOUT" "$PI_BIN" --print --approve \
    --model "$MODEL" --thinking "$THINKING" \
    --name "ai-radar $DATE" --session-dir "$SESSION_DIR" --session-id "$SESSION_ID" \
    --tools read,write,edit,web_search,fetch_content,get_search_content \
    "$PROMPT" >>"$LOG" 2>&1
  rc=$?
  size=0; [ -f "$REPORT" ] && size=$(wc -c <"$REPORT")

  # 取证：从 session 文件数本轮真实的 web_search 调用次数，防“零检索凭记忆交作业”
  sess_file="$(ls -t "$SESSION_DIR"/*_"$SESSION_ID".jsonl 2>/dev/null | head -1)"
  searches=0
  [ -n "$sess_file" ] && searches=$(grep -o '"name":"web_search"' "$sess_file" | wc -l)
  log "-- attempt $attempt 结束：exit=$rc report_bytes=$size 真实检索=$searches 次 --"

  if [ "$rc" -eq 0 ] && [ "$size" -ge "$MIN_REPORT_BYTES" ] && [ "$searches" -ge "$MIN_SEARCHES" ]; then
    status="ok"; break
  fi
  if [ "$rc" -eq 0 ] && [ "$searches" -lt "$MIN_SEARCHES" ]; then
    log "无效：本轮实际检索 $searches 次（需 ≥$MIN_SEARCHES），报告可能凭空生成"
  fi
  if [ "$attempt" -lt "$ATTEMPTS" ]; then log "本次未产出有效报告，60s 后重试（复用同一 session）"; sleep 60; fi
done

# 项目内保留策略（~/z/z-clean.timer 已把本项目排除，所以这里自己管）
prune() { find "$1" -maxdepth 1 -type f -name "$2" -mtime +"$3" -delete 2>/dev/null; }
prune "$PROJECT_DIR/reports" '*.md' "$KEEP_REPORT_DAYS"
prune "$LOG_DIR" '*.log' "$KEEP_LOG_DAYS"
prune "$SESSION_DIR" '*.jsonl' "$KEEP_LOG_DAYS"

# 落账到 git（推送失败不改变任务成败：日报才是主要产出）
push_note=""
if [ "$status" = "ok" ] && git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]; then
    git -C "$PROJECT_DIR" add -A -- . >>"$LOG" 2>&1
    if git -C "$PROJECT_DIR" commit -q -m "report: $DATE" >>"$LOG" 2>&1; then
      log "git: 已提交 report: $DATE"
    else
      log "WARN: git commit 失败"
    fi
  else
    log "git: 无变更，跳过提交"
  fi
  if timeout 120 git -C "$PROJECT_DIR" push --quiet origin HEAD >>"$LOG" 2>&1; then
    log "git: 已推送 origin"
  else
    push_note="（git push 未成功，本地提交已保留，详见 logs/$DATE.log）"
    log "WARN: git push 失败"
  fi
fi

if [ "$status" = "ok" ]; then
  body="$(headlines 3)"
  [ -n "$body" ] || body="报告已生成：reports/$DATE.md"
  [ -n "$push_note" ] && body="$body"$'\n'"$push_note"
  notify "AI Radar $DATE · $(printf '%s\n' "$body" | grep -c '^•') 条必读" "$body" normal
  log "===== 成功：$REPORT（$(wc -c <"$REPORT") 字节）====="
  exit 0
fi

notify "AI Radar $DATE 抓取失败" "已重试 $ATTEMPTS 次，详见 logs/$DATE.log" critical
log "===== 失败：多次尝试后仍未产出有效报告 ====="
exit 1
