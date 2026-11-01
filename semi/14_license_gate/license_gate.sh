#!/usr/bin/env bash
# semi/14_license_gate · License 门禁（EDA 许可证并发管控）
# 用法：./license_gate.sh up | verify | status | clean
#   up     license-mock 容器上线（池 3，TTL 120s）+ 推 license_gate job 进 rtl-gcd
#   verify ①4 路并发抢 3 个令牌：3 立即获得、第 4 个排队等待、全部归还
#          ②kill -9 一个持租容器 → TTL 到期自动回收 available 回 3
#   status license-mock 状态
#   clean  删 license-mock 容器（yml 里的 job 定义保留）
set -uo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
WORK="../08_lint_gate/.work/rtl-gcd"
NET="semi-gitlab_default"
SERVER="http://license-mock:9001"
POOL=3
TTL=120
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

start_server() {
    docker rm -f license-mock >/dev/null 2>&1 || true
    mkdir -p data
    echo "$POOL" > data/pool
    echo "$TTL" > data/ttl
    docker run -d --name license-mock --restart unless-stopped \
        --label dev.orbstack.group=semi-cicd \
        --network "$NET" \
        -v "$PWD/data:/config" \
        -v "$PWD/configs/license_server.py:/app/server.py:ro" \
        -p 127.0.0.1:28261:9001 \
        docker.m.daocloud.io/library/python:3.12-slim python /app/server.py >/dev/null
    sleep 2
    curl -sf "http://localhost:28261/health" >/dev/null &&
        pass "license-mock 就绪（pool=$POOL ttl=${TTL}s，宿主探针 :28261）" ||
        { fail "license-mock 未就绪"; docker logs license-mock | tail -3; exit 1; }
}

do_up() {
    step up "license-mock 上线"
    start_server
    step yml "rtl-gcd 加 license_gate job（幂等）"
    [ -d "$WORK/.git" ] || { echo "[fail] 先跑 08 的 ./lint_gate.sh up"; exit 1; }
    git -C "$WORK" checkout -q main && git -C "$WORK" pull -q origin main
    if grep -q "license_gate" "$WORK/.gitlab-ci.yml"; then
        echo "[  =] license_gate job 已在 yml"
        return 0
    fi
    cat >> "$WORK/.gitlab-ci.yml" <<'Y'

# ── 14 加装：License 门禁（with_license 包装：检出→仿真→归还）──
license_gate:
  stage: sim
  needs: [unit]
  image: localhost:28250/semi/eda-base:1.0
  tags: [eda]
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH == "main"
  script:
    - curl -s http://license-mock:9001/health
    - LICENSE_SERVER=http://license-mock:9001 bash tools/with_license.sh "license-gate-$CI_JOB_ID" python3 sim/run_tests.py
Y
    python3 - "$WORK" <<'PY'
import sys
f = sys.argv[1] + "/.gitlab-ci.yml"
s = open(f).read()
open(f, "w").write(s)
PY
    mkdir -p "$WORK/tools"
    cp configs/with_license.sh "$WORK/tools/with_license.sh"
    cp configs/lic.py "$WORK/tools/lic.py"
    git -C "$WORK" add .gitlab-ci.yml tools/with_license.sh tools/lic.py
    git -C "$WORK" commit -qm "ci: license 门禁（with_license 包装，池 3）"
    git -C "$WORK" push -q origin main
    pass "license_gate job 已推 main"
}

# 一个"持租工作进程"容器：acquire → 持有 hold 秒 → release；日志写本地 data/
run_holder() {
    local name="$1" hold="$2" tag="$3"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --network "$NET" \
        -v "$PWD/configs/with_license.sh:/wl.sh:ro" -v "$PWD/configs/lic.py:/lic.py:ro" \
        -v "$PWD/data:/data" \
        docker.m.daocloud.io/library/python:3.12-slim \
        bash -c "LICENSE_SERVER=http://license-mock:9001 bash /wl.sh \"$tag\" sleep $hold > /data/$name.log 2>&1" >/dev/null
}

do_verify() {
    local FAILED=0
    start_server   # 每轮验证从空池开始

    step verify1 "4 路并发抢 3 令牌：3 立即获得，第 4 个排队等待"
    for i in 1 2 3; do run_holder "holder-$i" 15 "job-$i"; done
    sleep 4
    local st
    st=$(curl -s --max-time 10 "http://localhost:28261/status")
    echo "  [  =] 3 holder 启动后 status: $st"
    if echo "$st" | grep -q '"available": 0'; then
        pass "3 个令牌全部检出（available=0）"
    else
        fail "available 应为 0：$st"; FAILED=1
    fi
    run_holder "holder-4" 15 "job-4"
    sleep 6
    if grep -q "lease wait" data/holder-4.log 2>/dev/null; then
        pass "第 4 路在 with_license 内排队（日志含 lease wait）"
    else
        fail "第 4 路未排队：$(tail -2 data/holder-4.log 2>/dev/null)"; FAILED=1
    fi
    # 等全部完成（3 holder 15s 释放 → holder-4 拿到 → 15s）
    for i in $(seq 1 30); do
        docker ps --format '{{.Names}}' | grep -q "holder-" || break
        sleep 5
    done
    local all_ok=1
    for i in 1 2 3 4; do
        grep -q "lease released" "data/holder-$i.log" 2>/dev/null || all_ok=0
    done
    if [ "$all_ok" = 1 ]; then
        pass "4 路全部走完 检出→执行→归还 生命周期"
    else
        fail "有 holder 未正常归还"; FAILED=1
    fi

    start_server   # 重置空池

    step verify2 "kill -9 持租容器 → TTL 到期自动回收"
    run_holder "holder-kill" 300 "job-kill"   # 持有 300s（远超 TTL，等被回收）
    sleep 4
    st=$(curl -s --max-time 10 "http://localhost:28261/status")
    echo "$st" | grep -q '"available": 2' &&
        pass "kill 前持有中（available=2）" ||
        fail "kill 前 available 应为 2：$st"
    docker kill --signal=KILL holder-kill >/dev/null 2>&1   # 模拟 job 被 kill -9
    echo "  [  =] 容器已 kill -9（无 release 调用）"
    local recovered=0
    for _ in $(seq 1 36); do   # TTL 120s，每 5s 查一次
        st=$(curl -s --max-time 10 "http://localhost:28261/status")
        echo "$st" | grep -q '"available": 3' && { recovered=1; break; }
        sleep 5
    done
    if [ "$recovered" = 1 ]; then
        pass "TTL 到期自动回收：available 回 3（无客户端 release）"
    else
        fail "TTL 回收失败：$st"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 14 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "license-mock"
    curl -s --max-time 10 "http://localhost:28261/status" | python3 -m json.tool 2>/dev/null | head -12
}

do_clean() {
    step clean "删 license-mock 与 holder 容器"
    docker rm -f license-mock holder-1 holder-2 holder-3 holder-4 holder-kill >/dev/null 2>&1 || true
    echo "[ok] 完成（rtl-gcd 的 job 定义保留）"
}

main() {
    local target="${1:-up}"
    case "${target}" in
        up)     do_up ;;
        verify) do_verify ;;
        status) do_status ;;
        clean)  do_clean ;;
        *) echo "用法: $0 up | verify | status | clean" >&2; exit 1 ;;
    esac
}
main "$@"
