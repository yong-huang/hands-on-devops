#!/usr/bin/env bash
# =============================================================================
# 01 · Splunk Enterprise 单机部署 — 主演示脚本
#
# 在 Apple Silicon（无官方 arm64 镜像）上以 Rosetta 2 模拟方式部署单机
# Splunk Enterprise 9.4：起容器 → REST 探活 → 版本/许可观察 → oneshot 灌入
# 标记数据 → 重启 → 数据仍在（持久化断言）→ 清理。
#
# ./splunk_deploy.sh up         起容器 + 探活（等待 splunkd REST 就绪）
# ./splunk_deploy.sh info       版本 / CPU 架构 / 许可证（剩余天数）/ 端口
# ./splunk_deploy.sh persist    oneshot 灌 5 条标记事件 → 重启 → 事件仍在
# ./splunk_deploy.sh stop       停容器（保留两卷数据，下次 up 直接续用）
# ./splunk_deploy.sh down       销毁容器+卷（回到实验前零残留状态）
# ./splunk_deploy.sh all        up → info → persist → down
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPL="https://localhost:28089"          # splunkd 管理 REST（自签 HTTPS）
WEB="http://localhost:28000"           # Splunk Web
MARKER_ST="splk_deploy_marker"         # 标记事件专用 sourcetype

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f .env ] || { cp .env.example .env; note "[ok] 已从 .env.example 生成 .env（默认密码）"; }
    # shellcheck disable=SC1091
    source .env
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail ".env 里没有 SPLUNK_PASSWORD"
}

# 探活：splunkd REST 返回含 version 即就绪。Rosetta 模拟 + 首次初始化 etc 卷
# 需要 1-2 分钟，上限给足 7 分钟（420s），不裸 sleep
wait_splunk() {
    local tag="$1" i=0
    note "等待 splunkd REST 就绪（${tag}，上限 420s）..."
    while :; do
        i=$((i+1)); [ $i -gt 84 ] && fail "$tag 后 420s 仍未就绪（看 docker logs splunk-deploy）"
        if curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null \
            | grep -q '<s:key name="version">'; then
            note "[ok] splunkd 就绪（约 $((i*5))s）"; return 0
        fi
        sleep 5
    done
}

# Splunk Web 比 splunkd REST 晚就绪（内嵌 nginx + splunkweb 启动滞后），
# REST 通了不代表 Web 通——单独轮询，同样不裸 sleep
wait_web() {
    local i=0 code=""
    note "等待 Splunk Web 就绪..."
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "Splunk Web 120s 未就绪（HTTP ${code:-无响应}）"
        code=$(curl -s -o /dev/null -w '%{http_code}' "${WEB}/en-US/" || true)
        { [ "$code" = "303" ] || [ "$code" = "200" ]; } && { note "[ok] Web 就绪（HTTP ${code}，约 $((i*5))s）"; return 0; }
        sleep 5
    done
}

# REST oneshot 搜索：同步返回结果 JSON（不用轮询 sid）。
# 注意 REST 的 search 参数不自动补隐式 search 命令——裸的 `index=main` 会报
# "Unknown search command 'index'"，必须显式以 `search ` 开头（Web UI 会补，REST 不会）
spl_search() {  # <SPL>（不带 search 前缀，本函数统一补）
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/search/jobs" \
        --data-urlencode "search=search $1" \
        --data-urlencode "exec_mode=oneshot" \
        --data-urlencode "output_mode=json" \
        --data-urlencode "earliest_time=0"
}

count_marker() {  # <run 标签> → 该标签的事件数
    spl_search "index=main sourcetype=$MARKER_ST run=$1 | stats count" \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['results'][0]['count'] if d.get('results') else 0)"
}

# oneshot 上传后事件不是瞬时可检索（索引落盘有秒级延迟）——轮询等到期望计数
# 出现为止；搜到但数目不对立即返回（切分问题，等再多也没用）
wait_count() {  # <run 标签> <期望值> → 输出计数（!=期望时供 fail 消息用）
    local tag="$1" want="$2" i=0 c=0
    while :; do
        i=$((i+1)); [ $i -gt 15 ] && { echo "$c"; return 1; }
        c=$(count_marker "$tag")
        [ "$c" = "$want" ] && { echo "$c"; return 0; }
        [ "$c" != "0" ] && { echo "$c"; return 1; }
        sleep 2
    done
}

do_up() {
    load_env
    step up "启动 Splunk Enterprise（amd64 镜像，Rosetta 模拟）"
    docker image inspect splunk/splunk:9.4 >/dev/null 2>&1 \
        || fail "本地没有 splunk/splunk:9.4。镜像源拉不动它（坏层/白名单），请直连：
        docker pull --platform linux/amd64 registry-1.docker.io/splunk/splunk:9.4
        docker tag registry-1.docker.io/splunk/splunk:9.4 splunk/splunk:9.4"
    docker compose up -d 2>&1 | sed 's/^/        /'
    wait_splunk "首次启动"
    wait_web
    ok "Splunk Web: ${WEB} （admin 登录）"
}

do_info() {
    load_env
    step info "版本 / 架构 / 许可证 / 端口"
    # server/info：cpu_arch=x86_64 是"确实在跑 amd64 代码"的直接证据
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info?output_mode=json" \
        | python3 -c "
import json, sys
c = json.load(sys.stdin)['entry'][0]['content']
print('        version :', c['version'])
print('        cpu_arch:', c['cpu_arch'], '  os:', c['os_name'])
print('        role    :', ','.join(c['server_roles']))"
    # 双重证据：镜像本身的平台声明
    note "image     : $(docker image inspect splunk/splunk:9.4 --format '{{.Os}}/{{.Architecture}}')"
    # 许可证：试用窗口剩余天数（清单排期 6 周，告警调度必须在窗口内完成）。
    # 关键字段是 expiration_time（epoch）——endDate 恒为 0，别用错
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/licenser/licenses?output_mode=json" \
        | python3 -c "
import json, sys, datetime
for e in json.load(sys.stdin)['entry']:
    c = e['content']
    if c.get('type') != 'download-trial':
        continue
    exp = datetime.datetime.fromtimestamp(int(c['expiration_time']))
    left = (exp - datetime.datetime.now()).days
    print(f\"        license : {c['label'].strip()} | 到期 {exp.date()} | 剩 {left} 天\")
    print(f\"        告警调度可用: {'Alerting' in c['features']} / 定时搜索: {'ScheduledSearch' in c['features']}\")"
    # Splunk Web 登录页探活：303 跳转到登录路由即正常
    wait_web
}

do_persist() {
    load_env
    step persist "oneshot 灌 5 条标记事件 → 重启 → 断言数据仍在"
    mkdir -p tmp
    local tag; tag="run$(date +%s)"
    # 5 行单行日志：默认按行切事件，正好 5 个事件。先截断——重复跑 persist
    # 时 >> 只会追加，旧 run 的行会混进本次上传（实测踩过：10 条事件就是这么来的）
    : > tmp/marker.log
    for i in 1 2 3 4 5; do
        echo "$(date '+%Y-%m-%d %H:%M:%S') [persist-demo] marker line $i/5 run=$tag" >> tmp/marker.log
    done
    docker cp tmp/marker.log splunk-deploy:/tmp/marker.log
    # oneshot：CLI 直接把一个文件灌成索引事件，不经 HEC/UF——最轻量的入库通道。
    # 必须 -u splunk：镜像默认 exec 用户是 ansible(999)，读不了 splunk 用户的
    # etc/var（报 Permission denied，上面那串 Cannot initialize 就是它）
    docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add oneshot /tmp/marker.log \
        -index main -sourcetype "$MARKER_ST" -auth "admin:${SPLUNK_PASSWORD}" >/dev/null \
        || fail "oneshot 上传失败"
    note "[ok] oneshot 上传完成（run=${tag}）"
    local before after
    before=$(wait_count "$tag" 5) || true
    [ "$before" = "5" ] || fail "重启前计数=${before}，期望 5（检索延迟上限 30s / 切分问题）"
    ok "重启前：run=$tag 事件数 = $before"
    step restart "docker compose restart（模拟进程重启）"
    docker compose restart 2>&1 | sed 's/^/        /'
    wait_splunk "重启后"
    after=$(count_marker "$tag")
    [ "$after" = "$before" ] || fail "重启后计数=${after}，重启前=${before} —— 数据丢了？！"
    ok "重启后：run=$tag 事件数 = $after —— var 卷持久化实证"
    # etc 卷同样要活：本地覆盖配置 telemetry.conf 重启后仍在
    docker exec -u splunk splunk-deploy test -f /opt/splunk/etc/system/local/telemetry.conf \
        && ok "etc 卷持久化：telemetry.conf 重启后仍在" \
        || fail "telemetry.conf 重启后消失——etc 卷没挂对"
}

do_stop() {
    step stop "停容器（保留 etc/var 两卷，下次 up 续用）"
    docker compose stop 2>&1 | sed 's/^/        /'
    ok "已停止；数据仍在 named volume 里"
}

do_down() {
    step down "销毁容器 + 卷（零残留断言）"
    docker compose down -v 2>&1 | sed 's/^/        /'
    local left
    left=$(docker volume ls -q | grep '^01_splunk_deploy' | wc -l | tr -d ' ')
    [ "$left" = "0" ] || fail "仍有 $left 个卷残留"
    docker inspect splunk-deploy >/dev/null 2>&1 && fail "容器 splunk-deploy 仍在"
    ok "容器与卷全部移除，回到实验前状态"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
        info)    do_info ;;
        persist) do_persist ;;
        stop)    do_stop ;;
        down)    do_down ;;
        all)     do_up; do_info; do_persist; do_down ;;
        *) echo "可用: up | info | persist | stop | down | all" >&2; exit 1 ;;
    esac
}

main "$@"
