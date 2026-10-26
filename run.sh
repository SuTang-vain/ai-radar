#!/usr/bin/env bash
# AI Radar — 每日 AI 动态扫描的执行器（由 ai-radar.timer 调用，也可手动跑）
#
#   ./run.sh              # 跑今天
#   ./run.sh 2026-10-01   # 回填某天（报告会写到 reports/2026-10-01.md）
#
# 可用环境变量覆盖：
#   AI_RADAR_MODEL / AI_RADAR_THINKING / AI_RADAR_TIMEOUT / AI_RADAR_ATTEMPTS
#   AI_RADAR_MIN_SEARCHES / AI_RADAR_REQUIRE / AI_RADAR_BUDGET_SEARCH / AI_RADAR_BUDGET_FETCH
#   AI_RADAR_CITATION_STRICT=1   # 引用无法溯源时判为无效报告（默认 0：只披露+告警）
#   AI_RADAR_KEEP_REPORTS / AI_RADAR_KEEP_LOGS
set -uo pipefail
export GIT_TERMINAL_PROMPT=0   # 凭据缺失时立即失败，别在无人值守时挂死等输入

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR" || exit 1

DATE="${1:-$(date +%F)}"
# 跨平台日期运算：Linux 用 GNU date -d，macOS 用 BSD date -j -v（BSD date 没有 -d）
week_start_for() { # <YYYY-MM-DD> → 6 天前
  date -d "$1 -6 days" +%F 2>/dev/null \
    || date -j -v-6d -f "%Y-%m-%d" "$1" +%F 2>/dev/null \
    || date -d '-6 days' +%F
}
WEEK_START="$(week_start_for "$DATE")"   # 滚动 7 天窗口起点
MODEL="${AI_RADAR_MODEL:-kimi-coding/kimi-for-coding-highspeed}"
THINKING="${AI_RADAR_THINKING:-high}"
RUN_TIMEOUT="${AI_RADAR_TIMEOUT:-1800}"        # 单次尝试上限（秒）
ATTEMPTS="${AI_RADAR_ATTEMPTS:-2}"
MIN_REPORT_BYTES=400                            # 低于此字节数视为无效报告
MIN_SEARCHES="${AI_RADAR_MIN_SEARCHES:-2}"      # 本轮至少要有这么多次真实 web_search
CITATION_STRICT="${AI_RADAR_CITATION_STRICT:-0}"  # 1 = 引用无法溯源即失败重试
# 报告必须包含的章节标题（| 分隔）；缺一即视为不合规报告，触发重试
REQUIRED_SECTIONS="${AI_RADAR_REQUIRE:-今日必读|最近一周产品情况|热度榜与风评|一手来源核查|抓取说明}"
BUDGET_SEARCH="${AI_RADAR_BUDGET_SEARCH:-12}"   # 与 prompt.md 的合计上限同源（由 run.sh 注入）
BUDGET_FETCH="${AI_RADAR_BUDGET_FETCH:-12}"
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

run_with_timeout() { # secs cmd...
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@"
  else
    # macOS 没有 GNU timeout：alarm 设在 perl 进程上，exec 后仍然有效
    perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

notify() { # title, body, urgency
  if [ "$(uname -s)" = "Darwin" ]; then
    osascript -e "display notification \"${2//\"/\\\"}\" with title \"${1//\"/\\\"}\"" >/dev/null 2>&1 || true
  else
    run_with_timeout 15 notify-send --app-name="AI Radar" --icon=dialog-information \
      -u "${3:-normal}" "$1" "$2" >/dev/null 2>&1 || log "WARN: notify-send 失败（无图形会话？）"
  fi
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

# URL 归一化：两侧用同一把尺子——去转义、协议、www、锚点/查询、末尾标点与斜杠
# （会话文本里的 URL 常带 markdown 的 `))` 尾巴，不剥掉就会全部比对失败）
norm_url() { sed -E 's#\\/#/#g; s#^https?://##; s#^www\.##; s#[#?].*$##; s#[)\]\}.,;:*]+$##; s#/$##'; }

[ -f "$PROJECT_DIR/prompt.md" ] || { log "FATAL: prompt.md 不存在"; notify "AI Radar 配置错误" "找不到 prompt.md" critical; exit 2; }
PROMPT="$(sed -e "s|{{WEEK_START}}|$WEEK_START|g" -e "s|{{DATE}}|$DATE|g" \
  -e "s|{{BUDGET_SEARCH}}|$BUDGET_SEARCH|g" -e "s|{{BUDGET_FETCH}}|$BUDGET_FETCH|g" \
  "$PROJECT_DIR/prompt.md")"
[ -n "$PROMPT" ] || { log "FATAL: prompt 渲染为空"; exit 2; }

log "===== ai-radar $DATE 开始（model=$MODEL, thinking=$THINKING, attempts=$ATTEMPTS）====="

status="fail"; attempt=0
missing_sections=""; searches=0; fetches=0; exa_upgrades=0
social_cites=0; tier_first=0; tier_second=0; fh_total=0; fh_verified=0; fh_unverified=0
total_cited=0; untraceable=0; untraceable_list=""; sess_file=""
while [ "$attempt" -lt "$ATTEMPTS" ]; do
  attempt=$((attempt + 1))
  log "-- attempt $attempt/$ATTEMPTS --"
  rm -f "$REPORT"   # 清掉旧文件，避免残留报告冒充本次成功
  # 每次尝试的输出单独落盘，便于定位「哪一次失败、为什么失败」
  attempt_out="$SESSION_DIR/out-$SESSION_ID-$attempt.log"
  run_with_timeout "$RUN_TIMEOUT" "$PI_BIN" --print --approve \
    --model "$MODEL" --thinking "$THINKING" \
    --name "ai-radar $DATE" --session-dir "$SESSION_DIR" --session-id "$SESSION_ID" \
    --tools read,write,edit,web_search,fetch_content,get_search_content \
    "$PROMPT" >"$attempt_out" 2>&1
  rc=$?
  cat "$attempt_out" >>"$LOG" 2>/dev/null

  # 余额不足属于账户级故障，重试无意义：立即终止，不空烧到超时
  if grep -q 'Insufficient Balance' "$attempt_out" 2>/dev/null; then
    log "FATAL: ${MODEL} 返回 Insufficient Balance（余额不足），任务终止并跳过剩余尝试"
    notify "AI Radar 余额不足" "${MODEL} 账户余额不足，今日日报未生成" critical
    rm -f "$attempt_out"
    exit 3
  fi
  size=0; [ -f "$REPORT" ] && size=$(wc -c <"$REPORT")

  # (a) 结构校验：必备章节标题是否齐全（提示词里已写明，缺失即不合规）
  missing_sections=""
  if [ -f "$REPORT" ]; then
    IFS='|' read -r -a _want <<< "$REQUIRED_SECTIONS"
    for _token in "${_want[@]}"; do
      grep -qF -- "$_token" "$REPORT" || missing_sections="$missing_sections$_token "
    done
  fi

  # (b) 取证：从 session 精确数真实工具调用（宽松 grep 会被文本里的同名字符串抬高）
  sess_file="$(ls -t "$SESSION_DIR"/*_"$SESSION_ID".jsonl 2>/dev/null | head -1)"
  searches=0; fetches=0; exa_upgrades=0; social_cites=0; tier_first=0; tier_second=0
  fh_total=0; fh_verified=0; fh_unverified=0; fh_unverified_list=""
  if [ -n "$sess_file" ]; then
    searches=$(grep -o '"type":"toolCall","id":"[^"]*","name":"web_search"' "$sess_file" | wc -l)
    fetches=$(grep -o '"type":"toolCall","id":"[^"]*","name":"fetch_content"' "$sess_file" | wc -l)
    exa_upgrades=$(grep -o '"name":"web_search","arguments":{[^}]*}' "$sess_file" | grep -c '"provider":"exa"')
    social_cites=$(grep -oE '\]\(https?://(www\.)?(x\.com|twitter\.com|reddit\.com|news\.ycombinator\.com|weibo\.com|zhihu\.com)/[^)]*' "$REPORT" 2>/dev/null | wc -l)
    tier_first=$(grep -o '【一手】' "$REPORT" 2>/dev/null | wc -l)
    tier_second=$(grep -o '【二手】' "$REPORT" 2>/dev/null | wc -l)
  fi

  # (c) 引文溯源：报告里每条引用 URL 必须在本轮 session 出现过（抓取过或出现在检索结果里）
  total_cited=0; untraceable=0; untraceable_list=""
  if [ -n "$sess_file" ] && [ -f "$REPORT" ]; then
    _pool="$(mktemp "${TMPDIR:-/tmp}/airadar-pool.XXXXXX")"; _cited="$(mktemp "${TMPDIR:-/tmp}/airadar-cited.XXXXXX")"
    grep -oE 'https?://[^"\\ )]+' "$sess_file" | norm_url | LC_ALL=C sort -u >"$_pool"
    grep -oE '\]\(https?://[^)]+\)' "$REPORT" | sed -E 's#^\]\(##; s#\)$##' | norm_url | LC_ALL=C sort -u >"$_cited"
    total_cited=$(wc -l <"$_cited")
    _missing="$(LC_ALL=C comm -23 "$_cited" "$_pool")"
    untraceable=$(printf '%s' "$_missing" | grep -c . )
    untraceable_list="$(printf '%s' "$_missing" | grep . | head -5 | tr '\n' ' ')"
    rm -f "$_pool" "$_cited"
  fi

  # (d) 一手取证：标了【一手】的断言行，其引用 URL 必须在本轮真的被抓取过（只读搜索摘要不算溯源）
  if [ -n "$sess_file" ] && [ -f "$REPORT" ]; then
    _fpool="$(mktemp "${TMPDIR:-/tmp}/airadar-fpool.XXXXXX")"
    grep -o '"name":"fetch_content","arguments":{[^}]*}' "$sess_file" | grep -oE 'https?://[^"]+' | norm_url | LC_ALL=C sort -u >"$_fpool"
    while IFS= read -r _line; do
      _urls="$(printf '%s' "$_line" | grep -oE '\]\(https?://[^)]+\)' | sed -E 's#^\]\(##; s#\)$##')"
      [ -n "$_urls" ] || continue
      fh_total=$((fh_total + 1))
      _hit=0
      while IFS= read -r _u; do
        [ -n "$_u" ] || continue
        if grep -qxF "$(printf '%s' "$_u" | norm_url)" "$_fpool"; then _hit=1; break; fi
      done <<< "$_urls"
      if [ "$_hit" -eq 1 ]; then fh_verified=$((fh_verified + 1)); else
        fh_unverified_list="$fh_unverified_list$(printf '%s' "$_line" | cut -c1-70) ｜"
      fi
    done < <(grep -E '^- .*【一手】' "$REPORT")
    fh_unverified=$((fh_total - fh_verified))
    rm -f "$_fpool"
  fi

  log "-- attempt $attempt 结束：exit=$rc report_bytes=$size 真实检索=${searches} 次（exa 升级 ${exa_upgrades} 次）/ 抓取=${fetches} 次 / 引用溯源 $((total_cited - untraceable))/$total_cited / 来源层级 一手${tier_first} 二手${tier_second} 社媒引用${social_cites} / 一手取证 ${fh_verified}/${fh_total} --"

  ok=1
  [ "$rc" -eq 0 ] || ok=0
  [ "$size" -ge "$MIN_REPORT_BYTES" ] || ok=0
  [ "$searches" -ge "$MIN_SEARCHES" ] || ok=0
  [ -z "$missing_sections" ] || ok=0
  { [ "$CITATION_STRICT" != "1" ] || [ "$untraceable" -eq 0 ]; } || ok=0

  if [ "$ok" -eq 1 ]; then status="ok"; break; fi

  [ -z "$missing_sections" ] || log "无效：报告缺少必备章节：$missing_sections"
  [ "$searches" -ge "$MIN_SEARCHES" ] || log "无效：本轮实际检索 $searches 次（需 ≥$MIN_SEARCHES），报告可能凭空生成"
  [ "$untraceable" -gt 0 ] && log "WARN: $untraceable 条引用无法在本轮会话中溯源：$untraceable_list"
  [ "$fh_unverified" -gt 0 ] && log "WARN: $fh_unverified 条【一手】断言的引用未被本轮抓取（疑为搜索摘要，应降级为【二手】）：$fh_unverified_list"
  if [ "$attempt" -lt "$ATTEMPTS" ]; then log "本次未产出有效报告，60s 后重试（复用同一 session）"; sleep 60; fi
done

# 项目内保留策略（~/z/z-clean.timer 已把本项目排除，所以这里自己管）
# BSD find 无 -delete，统一用 -exec rm（GNU/BSD 均可用）
prune() { find "$1" -maxdepth 1 -type f -name "$2" -mtime +"$3" -exec rm -f {} + 2>/dev/null; }
prune "$PROJECT_DIR/reports" '*.md' "$KEEP_REPORT_DAYS"
prune "$LOG_DIR" '*.log' "$KEEP_LOG_DAYS"
prune "$SESSION_DIR" '*.jsonl' "$KEEP_LOG_DAYS"
prune "$SESSION_DIR" 'out-*.log' "$KEEP_LOG_DAYS"

# 运行器举证与来源披露：把可验证的事实写进报告本身
if [ "$status" = "ok" ] && [ -n "$sess_file" ]; then
  # 头部：来源通道 + 真实调用量 + 溯源结果，读者一眼知道这批信息的来路
  if ! grep -q '信息来源（运行器写入）' "$REPORT"; then
    if [ "$searches" -gt 0 ] && [ "$exa_upgrades" -ge "$searches" ]; then
      channel="检索通道 Exa（显式指定，${exa_upgrades}/${searches} 次）"
    elif [ "$exa_upgrades" -gt 0 ]; then
      channel="检索通道 Exa ${exa_upgrades} 次 + 默认路由 ${searches}−${exa_upgrades} 次（Kimi Code API，失败降级 exa → duckduckgo）"
    else
      channel="检索通道 Kimi Code API（默认路由，失败降级 exa → duckduckgo）"
    fi
    src_note="> **信息来源（运行器写入）**：${channel}，抓取通道 Jina Reader → 直连 HTTP。本轮真实调用：web_search ${searches} 次 / fetch_content ${fetches} 次；引文溯源 $((total_cited - untraceable))/${total_cited} 条可在本轮会话中追溯；来源层级标注：一手 ${tier_first} 条 / 二手 ${tier_second} 条；一手取证：${fh_verified}/${fh_total} 条【一手】断言的引用确为本轮抓取过$( [ "$fh_unverified" -gt 0 ] && printf '，**其中 %s 条仅凭搜索摘要（应降级为【二手】）**' "$fh_unverified" )。"
    { head -1 "$REPORT"; printf '\n%s\n' "$src_note"; tail -n +2 "$REPORT"; } >"$REPORT.tmp" && mv "$REPORT.tmp" "$REPORT"
    log "已写入来源披露（exa 升级 ${exa_upgrades} 次 / 溯源 ${total_cited}-${untraceable}/${total_cited}）"
  fi
  # 尾部：取证行（模型自述实测会少报：曾把 9 次抓取写成 8 次）
  if ! grep -q '运行器取证' "$REPORT"; then
    printf -- '- 运行器取证（run.sh 解析 session 的 toolCall，非模型自述）：web_search %s 次 / fetch_content %s 次（预算上限 %s / %s）\n' \
      "$searches" "$fetches" "$BUDGET_SEARCH" "$BUDGET_FETCH" >>"$REPORT"
    log "已追加运行器取证：检索 $searches / 抓取 $fetches"
  fi
  [ "$searches" -gt "$BUDGET_SEARCH" ] && log "WARN: 超出检索预算（$searches > $BUDGET_SEARCH）"
  [ "$fetches" -gt "$BUDGET_FETCH" ] && log "WARN: 超出抓取预算（$fetches > $BUDGET_FETCH）"
  [ "$untraceable" -gt 0 ] && log "WARN: 存在无法溯源的引用，已在报告头部标明"
  [ "$social_cites" -gt 0 ] && log "WARN: 报告含 $social_cites 条社交平台引用（只能作线索，须回溯一手来源）"
fi

# 落账到 git（推送失败不改变任务成败：日报才是主要产出）
# 卡片按钮指向 REPORT_BASE_URL；只有它非空时，「报告是否真的推上去」才影响要不要发飞书
REPORT_BASE_URL="$(sed -n 's/^REPORT_BASE_URL=//p' "$PROJECT_DIR/config.env" 2>/dev/null | head -1)"
push_note=""
push_ok=1   # 0 = 报告没真正上去；卡片按钮会 404，此时不能发飞书
if [ "$status" = "ok" ] && git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git -C "$PROJECT_DIR" status --porcelain 2>/dev/null)" ]; then
    git -C "$PROJECT_DIR" add -A -- . >>"$LOG" 2>&1
    if git -C "$PROJECT_DIR" commit -q -m "report: $DATE" >>"$LOG" 2>&1; then
      log "git: 已提交 report: $DATE"
    else
      # 无人值守环境（cron/systemd）最常见原因：没有 user.name / user.email
      push_ok=0
      log "FATAL: git commit 失败（无人值守环境多为未配置 user.name/user.email）"
    fi
  else
    log "git: 无变更，跳过提交"
  fi
  if run_with_timeout 120 git -C "$PROJECT_DIR" push --quiet origin HEAD >>"$LOG" 2>&1; then
    log "git: 已推送 origin"
  else
    push_ok=0
    push_note="（git push 未成功，本地提交已保留，详见 logs/$DATE.log）"
    log "WARN: git push 失败"
  fi
fi

# 可选飞书推送：脚本存在且配了 webhook 才发，失败不影响任务成败
# 但报告没推送成功时不发 —— 卡片按钮指向 REPORT_BASE_URL，点开必然 404
if [ "$status" = "ok" ] && [ -x "$PROJECT_DIR/push-feishu.sh" ]; then
  if [ "$push_ok" != "1" ] && [ -n "$REPORT_BASE_URL" ]; then
    log "WARN: 报告未推送成功，跳过飞书推送（否则卡片按钮会 404）"
  elif "$PROJECT_DIR/push-feishu.sh" "$DATE" >>"$LOG" 2>&1; then
    log "飞书: 卡片已推送"
  else
    log "WARN: 飞书推送失败（不影响任务成败）"
  fi
fi

if [ "$status" = "ok" ]; then
  body="$(headlines 3)"
  [ -n "$body" ] || body="报告已生成：reports/$DATE.md"
  [ -n "$push_note" ] && body="$body"$'\n'"$push_note"
  notify "AI Radar $DATE · $(printf '%s\n' "$body" | grep -c '^•') 条必读" "$body" normal
  log "===== 成功：$REPORT（$(wc -c <"$REPORT") 字节，检索 $searches / 抓取 $fetches）====="
  exit 0
fi

notify "AI Radar $DATE 抓取失败" "已重试 $ATTEMPTS 次，详见 logs/$DATE.log" critical
log "===== 失败：多次尝试后仍未产出有效报告 ====="
exit 1
