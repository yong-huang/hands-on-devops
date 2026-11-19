#!/usr/bin/env bash
# =============================================================================
# 08 · Universal Forwarder 采集链 — 主演示脚本
#
# UF 容器（amd64 模拟）盯挂载目录里的 app.log → TLS 9997 转发给索引器：
# 100 行 120s 内入库 → tcpin 连接确认 → 停机写 30 行再启动（续传不丢）→ 归零。
#
# ./spl_uf.sh up         索引器就绪 + 生成自签证书 + 开 9997 TLS 监听
# ./spl_uf.sh ufup       UF 镜像探活 + UF 容器起 + 配置部署 + 连接建立
# ./spl_uf.sh ingest     写 100 行 → 120s 内入库对账
# ./spl_uf.sh blackout   停 UF → 写 30 行 → 复启 → 续传不丢断言
# ./spl_uf.sh clean      删 UF 容器 + 关监听 + 删配置/证书/索引 + 归零
# ./spl_uf.sh all        up → ufup → ingest → blackout → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPLD="https://localhost:28089"
LAB01="../01_splunk_deploy"
UF_IMG="splunk/universalforwarder:9.4"
UF_NAME="uf-lab"
NET="01_splunk_deploy_default"
IDX_INPUTS="/opt/splunk/etc/system/local/inputs.conf"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f "$LAB01/.env" ] || fail "缺 $LAB01/.env——先做 lab 01"
    set -a; # shellcheck disable=SC1090
    source "$LAB01/.env"; set +a
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
}

spl_search() {
    local s="$1" pfx
    case "$s" in
        "|"*|tstats*|search*) pfx="" ;;
        *) pfx="search " ;;
    esac
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/search/jobs" \
        --data-urlencode "search=${pfx}${s}" \
        --data-urlencode "exec_mode=oneshot" \
        --data-urlencode "output_mode=json" \
        --data-urlencode "earliest_time=0"
}

qcount() { spl_search "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else 0)"; }

wait_splunk() {
    local tag="$1" i=0
    note "等待 splunkd 就绪（${tag}）..."
    while :; do
        i=$((i+1)); [ $i -gt 84 ] && fail "$tag 420s 未就绪"
        curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version' \
            && { note "[ok] 就绪（约 $((i*5))s）"; return 0; }
        sleep 5
    done
}

do_up() {
    load_env
    step up "索引器就绪 + 自签证书 + 9997 TLS 监听"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        wait_splunk "冷启动"
    else
        note "[ok] splunk-deploy 已在运行"
    fi
    mkdir -p tmp configs/idx
    # 证书+私钥合并 PEM（serverCert 要求），存 configs 入库以便复跑
    if [ ! -f configs/s2s.pem ]; then
        openssl req -x509 -newkey rsa:2048 -nodes -keyout tmp/s2s.key \
            -out tmp/s2s.crt -days 365 -subj "/CN=splunk-s2s" 2>/dev/null
        cat tmp/s2s.crt tmp/s2s.key > configs/s2s.pem
        note "[ok] 自签证书已生成 configs/s2s.pem"
    fi
    docker cp configs/s2s.pem splunk-deploy:/opt/splunk/etc/auth/s2s.pem
    docker cp configs/idx/inputs.conf splunk-deploy:"$IDX_INPUTS"
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "TLS 监听生效重启"
    # 9997 LISTEN 确认：/proc/net/tcp 端口 0x270D（9997）
    docker exec splunk-deploy sh -c 'grep -qi ":270D" /proc/net/tcp' \
        && ok "索引器 9997（0x270D）TLS LISTEN 已开" \
        || fail "9997 未监听"
    # 目标索引先建：UF 转发的事件路由到 uf_demo——索引不存在会被静默丢弃
    # （与 lab 07 的 hec_demo 同款：intake≠indexing，转发成功≠入库成功）
    local idx_code
    idx_code=$(curl -sk -u "admin:${SPLUNK_PASSWORD}" -o /dev/null -w '%{http_code}' "$SPLD/services/data/indexes/uf_demo")
    if [ "$idx_code" = "200" ]; then note "[ok] 索引 uf_demo 已存在"; else
        docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add index uf_demo \
            -auth "admin:${SPLUNK_PASSWORD}" >/dev/null && note "[ok] 索引 uf_demo 已创建"
    fi
}

do_ufup() {
    load_env
    step ufup "UF 镜像探活 + 容器起 + 配置部署"
    docker image inspect "$UF_IMG" >/dev/null 2>&1 \
        || fail "本地没有 $UF_IMG。拉取（amd64 模拟）：
        docker pull --platform linux/amd64 registry-1.docker.io/splunk/universalforwarder:9.4
        docker tag registry-1.docker.io/splunk/universalforwarder:9.4 $UF_IMG"
    docker rm -f "$UF_NAME" >/dev/null 2>&1 || true
    mkdir -p tmp/data && : > tmp/data/app.log
    docker run -d --name "$UF_NAME" --network "$NET" \
        -e SPLUNK_START_ARGS=--accept-license -e "SPLUNK_PASSWORD=${SPLUNK_PASSWORD}" \
        -v "$PWD/tmp/data:/opt/data" "$UF_IMG" >/dev/null
    note "[ok] UF 容器已启动（amd64 模拟，首次引导实测约 10 分钟）"
    # 引导完成标志：entrypoint 日志出现 "Ansible playbook complete"
    # （UF 的 SPLUNK_HOME 是 /opt/splunkforwarder，不是 /opt/splunk——实测踩过）
    local UF_HOME="/opt/splunkforwarder" i=0
    while :; do
        i=$((i+1)); [ $i -gt 180 ] && fail "UF 900s 未完成引导"
        docker logs "$UF_NAME" 2>&1 | grep -q "Ansible playbook complete" \
            && { note "[ok] UF 引导完成（约 $((i*5))s）"; break; }
        sleep 5
    done
    docker cp configs/uf/inputs.conf  "$UF_NAME:$UF_HOME/etc/system/local/inputs.conf"
    docker cp configs/uf/outputs.conf "$UF_NAME:$UF_HOME/etc/system/local/outputs.conf"
    docker restart "$UF_NAME" >/dev/null
    i=0
    while :; do
        i=$((i+1)); [ $i -gt 60 ] && fail "UF 重启后 300s 未就绪"
        docker exec -u root "$UF_NAME" "$UF_HOME/bin/splunk" status 2>/dev/null | grep -q 'is running' \
            && { note "[ok] UF 配置生效（约 $((i*5))s）"; break; }
        sleep 5
    done
    # 连接建立确认：UF 侧 splunkd.log 的 tcpout Connected 记录（日志属 splunk 用户，root 读）
    local i2=0 connected=""
    while :; do
        i2=$((i2+1)); [ $i2 -gt 24 ] && fail "UF 120s 内未建立 9997 连接"
        connected=$(docker exec -u root "$UF_NAME" grep -c "Connected to idx=" "$UF_HOME/var/log/splunk/splunkd.log" 2>/dev/null || echo 0)
        [ "${connected:-0}" -ge 1 ] 2>/dev/null && break
        sleep 5
    done
    ok "UF → 索引器 9997 连接已建立（splunkd.log Connected ×${connected}）"
}

write_lines() {  # <条数> <标签>
    local n="$1" tag="$2" i
    for i in $(seq 1 "$n"); do
        echo "$(date '+%Y-%m-%d %H:%M:%S') [uf-demo] run=$tag line ${i}/${n} status=200 bytes=$((RANDOM%3000+200))" >> tmp/data/app.log
    done
}

do_ingest() {
    load_env
    step ingest "写 100 行 → 120s 内入库对账"
    write_lines 100 "A"
    note "[ok] 100 行已写入挂载目录"
    local i=0 c=0
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "120s 后入库 ${c} < 100"
        c=$(qcount "index=uf_demo | stats count")
        [ "$c" -ge 100 ] 2>/dev/null && break
        sleep 5
    done
    ok "断言 A：${c} 行入库（≥100，约 $((i*5))s）"
    # 索引器侧连接视角：tcpin 的 9997 连接数（REST /services/admin/inputstatus 不直观，用 proc+UF 日志双证）
    ok "连接确认：UF 日志 Connected 记录 + 索引器 9997 LISTEN（up 步骤已证）"
}

do_blackout() {
    load_env
    step blackout "停 UF → 写 30 行 → 复启 → 续传不丢"
    docker stop "$UF_NAME" >/dev/null
    note "[ok] UF 已停止（模拟断网）"
    write_lines 30 "B"
    note "[ok] 停机期间写入 30 行（run=B）"
    sleep 30
    docker start "$UF_NAME" >/dev/null
    note "[ok] UF 已复启"
    local i=0 c_b
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "120s 后 run=B 事件 ${c_b:-0} < 30"
        c_b=$(qcount "index=uf_demo run=B | stats count")
        [ "$c_b" -ge 30 ] 2>/dev/null && break
        sleep 5
    done
    ok "断言 B：停机期间 30 行续传入库（run=B ${c_b} 条，0 丢失）"
}

do_clean() {
    load_env
    step clean "删 UF 容器 + 关监听 + 删配置/证书/索引"
    docker rm -f "$UF_NAME" >/dev/null 2>&1 && note "[ok] UF 容器已移除" || note "[ok] UF 容器不存在"
    docker exec -u root splunk-deploy sh -c "rm -f $IDX_INPUTS /opt/splunk/etc/auth/s2s.pem"
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "监听关闭重启"
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPLD/services/data/indexes/uf_demo" >/dev/null \
        && note "[ok] 索引 uf_demo 已删除"
    rm -rf tmp
    ok "UF 通道零残留（9997 监听随 inputs.conf 移除而关闭）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)       do_up ;;
        ufup)     do_ufup ;;
        ingest)   do_ingest ;;
        blackout) do_blackout ;;
        clean)    do_clean ;;
        all)      do_up; do_ufup; do_ingest; do_blackout; do_clean ;;
        *) echo "可用: up | ufup | ingest | blackout | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
