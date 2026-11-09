#!/usr/bin/env bash
# =============================================================================
# 08 · pg backend 真锁并发 — 主演示脚本
#
# 面试最高频考点现场复现（全部真机断言，不是背书）：
#   [并发]  终端 A apply 持锁窗口内，终端 B apply → "Error acquiring the state lock"
#   [可见]  pg_locks 表里 advisory 锁当场可查——锁不是黑盒
#   [假死]  SIGSTOP 持锁进程（连接在、锁在）→ 第三者照样被拦 → 这就是"锁卡死"
#   [强解]  DBA 式 pg_terminate_backend 干掉持有者连接 → 锁释放 → 一切恢复
#   [诚实]  terraform force-unlock 在 pg 后端上的真实行为也录下来（报成功但锁不动）
#
# ./pg_backend_lock.sh up      起 postgres 后端容器（健康等待）
# ./pg_backend_lock.sh init    初始化 TF 工作区（pg backend）
# ./pg_backend_lock.sh demo    锁竞争三场景 + 全部断言
# ./pg_backend_lock.sh verify  终态断言（plan 干净/资源在 state/state 落库）
# ./pg_backend_lock.sh clean   销毁一切，零残留
# ./pg_backend_lock.sh all     上面五步一条龙
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# provider 走仓库内置 filesystem mirror（scripts/tfrc.sh）——离线秒装，
# 不吃 registry.terraform.io / releases.hashicorp.com 的网络波动
. "../../scripts/tfrc.sh"

PG_NAME="tf08-postgres"
PG_PORT=15432
WORK="tmp/work"
PASS=0 FAIL=0
APID=""

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
pg()   { docker exec "$PG_NAME" psql -U terraform -d terraform_state -tA -c "$1"; }

# 断言计数器：演示末尾统一汇报，FAIL 非零则整个脚本退出非零
assert() {
    local desc="$1" rc="$2"
    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS+1)); note "[ok]   $desc"
    else
        FAIL=$((FAIL+1)); note "[FAIL] $desc"
    fi
}

# 布尔表达式转断言码：expr 成立 → 0（过），否则 → 1（挂）
# （不经手 $?，避免 set -e 在 assert 之前抢先杀掉脚本）
okif() { [ "$1" -eq 0 ] && return 0 || return 1; }

# 后台 apply 若还活着，收尾时补刀——必须连 provider 插件子进程一起杀：
# provider 是独立进程，只杀 CLI 的话它会"诈尸"完成半途的 apply
# （本机实测：40 分钟前被击毙的 apply 在引擎恢复后把容器创建了出来）
kill_A() {
    if [ -n "$APID" ] && kill -0 "$APID" 2>/dev/null; then
        pkill -9 -P "$APID" 2>/dev/null || true
        kill -9 "$APID" 2>/dev/null || true
    fi
}
trap kill_A EXIT

do_up() {
    step "up" "起 PostgreSQL 后端容器（postgres:16-alpine，宿主端口 ${PG_PORT}）"
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
    docker run -d --name "$PG_NAME" \
        -e POSTGRES_USER=terraform -e POSTGRES_PASSWORD=terraform \
        -e POSTGRES_DB=terraform_state -p "$PG_PORT:5432" \
        postgres:16-alpine >/dev/null
    local i=0
    until docker exec "$PG_NAME" pg_isready -U terraform -d terraform_state >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] postgres 30s 未就绪" >&2; exit 1; }
        sleep 1
    done
    note "[ok] postgres 就绪（状态库 terraform_state @ :${PG_PORT}）"
}

do_init() {
    step "init" "初始化 TF 工作区（pg backend；工作目录 ${WORK}，configs 保持纯净）"
    mkdir -p "$WORK"
    cp configs/*.tf "$WORK/"
    # 新起的 postgres 在 pg_isready 通过后仍有短暂预热窗口（backend 握手偶发
    # EOF，本机实测复现过），三次重试以内必稳——比 sleep 赌时长诚实
    local attempt rc=1 out
    for attempt in 1 2 3; do
        rc=0
        out=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform init -input=false -no-color ) 2>&1 ) || rc=$?
        echo "$out" | grep -E "Initializing|Terraform has been|Error|backend" | sed 's/^/        /'
        [ "$rc" -eq 0 ] && break
        note "[i] 第 ${attempt} 次 init 失败（backend 握手预热竞态），2s 后重试……"
        sleep 2
    done
    [ "$rc" -eq 0 ] || { echo "    [!] init 三次均失败，检查 postgres 状态" >&2; exit 1; }
    note "[ok] backend = pg @ localhost:${PG_PORT}/terraform_state"
}

do_demo() {
    step "demo" "场景一【并发撞锁】：A 持锁窗口内 B 强行 apply"
    [ -d "$WORK" ] || { echo "    [!] 工作区不存在——先跑 ./pg_backend_lock.sh init" >&2; exit 1; }
    # 后台起 A（不能套子壳：SIGSTOP/SIGKILL 必须直接命中 terraform 进程本体）
    cd "$WORK"
    TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=45s" > ../applyA.log 2>&1 &
    APID=$!
    disown "$APID" 2>/dev/null || true   # 脱离 job 表：之后 SIGKILL 不打 "Killed: 9" 噪音
    cd - >/dev/null
    note "A 已后台启动（pid=${APID}，日志 applyA.log），等它持锁……"

    # 等 advisory 锁出现（锁由数据库亲自记账，pg_locks 当场可查——不是黑盒）
    local i=0 n=""
    until n=$(pg "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted") && [ "${n:-0}" -ge 1 ]; do
        i=$((i+1)); [ $i -gt 60 ] && { echo "    [!] 60s 内未见 advisory 锁，A 日志：" >&2; tail -5 applyA.log >&2; exit 1; }
        sleep 1
    done
    note "A 已持锁（后台 apply，日志 applyA.log），pg_locks 里 advisory granted=${n}"
    okif $([ "${n:-0}" -ge 1 ] && echo 0 || echo 1); assert "pg_locks 可见 advisory 持锁记录（锁不是黑盒）" $?

    # B 强行 apply → 必须被锁拦下
    local brc=0 berr
    berr=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=1s" ) 2>&1 ) || brc=$?
    local bok=1
    echo "$berr" | grep -q "Error acquiring the state lock" && bok=0
    assert "B 被拦且报错含 'Error acquiring the state lock'" "$bok"
    local LOCK_ID
    LOCK_ID=$(echo "$berr" | grep -A1 "Lock Info" | grep "ID:" | awk '{print $2}' | head -1)
    note "锁信息已随报错吐出：Lock ID = ${LOCK_ID:-<未取到>}"

    step "demo" "场景二【假死滞留】：SIGSTOP A——连接还在、锁还在"
    kill -STOP "$APID"; note "A 已被 SIGSTOP 冻结（假死：进程在，进度走不了，连接没断）"
    sleep 1
    local crc=0
    ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=1s" >/dev/null 2>&1 ) || crc=$?
    local cok=1
    [ "$crc" -ne 0 ] && cok=0
    assert "假死期间 C 同样被拦（这就是'锁卡死'事故原型）" "$cok"

    step "demo" "场景三【强解】：先试 terraform force-unlock，再上 DBA 手段"
    if [ -n "${LOCK_ID:-}" ]; then
        local fu_out fu_rc=0
        fu_out=$( ( cd "$WORK" && terraform force-unlock -force "$LOCK_ID" ) 2>&1 ) || fu_rc=$?
        echo "$fu_out" | sed 's/^/        | /'
        note "↑ force-unlock 在 pg 后端的真实行为（退出码 ${fu_rc}）——报成功但锁不动，README 讨论"
    fi
    # DBA 式强解：找到持有 advisory 锁的后端连接，掐断它（pg 语义：连接亡，锁归西）
    local holder_pid
    holder_pid=$(pg "SELECT pid FROM pg_locks WHERE locktype='advisory' AND granted LIMIT 1")
    pg "SELECT pg_terminate_backend($holder_pid)" >/dev/null
    sleep 1
    n=$(pg "SELECT count(*) FROM pg_locks WHERE locktype='advisory' AND granted")
    local gok=1
    [ "${n:-0}" -eq 0 ] && gok=0
    assert "pg_terminate_backend 掐断持有者连接 → 锁归零（granted=${n}）" "$gok"

    # 收尾：假死的 A 已无意义，补刀（disown 过，不会有 job 噪音）
    kill_A
    step "demo" "恢复：D 正常 apply（接手 A 的半成品 state）"
    local drc=0 dout
    dout=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=1s" ) 2>&1 ) || drc=$?
    echo "$dout" | tail -3 | sed 's/^/        /'
    assert "锁释放后 D apply 成功（无残留卡死）" "$drc"

    echo
    note "断言汇总：PASS=${PASS} FAIL=${FAIL}"
    [ "$FAIL" -eq 0 ] || exit 1
}

do_verify() {
    step "verify" "终态断言：plan 干净 / 资源在 state / state 落库"
    local prc=0
    ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform plan -input=false -no-color -var "hold_seconds=1s" 2>/dev/null \
        | grep -q "No changes" ) || prc=$?
    assert "terraform plan → No changes（终态收敛）" "$prc"

    local src=0
    ( cd "$WORK" && terraform state list ) 2>/dev/null | grep -q "docker_image.demo" || src=$?
    assert "state 里有 docker_image.demo（被锁保护的资源在册）" "$src"

    local n
    n=$(pg "SELECT count(*) FROM \"terraform_remote_state\".states")
    local drc=1
    [ "${n:-0}" -ge 1 ] && drc=0
    assert "state 已落库（pg 后端表 terraform_remote_state.states 有记录）" "$drc"

    local out orc=0
    out=$( ( cd "$WORK" && terraform output -raw demo_image ) 2>&1 ) || orc=$?
    local ook=1
    [ "$orc" -eq 0 ] && [ "$out" = "alpine:3" ] && ook=0
    assert "output 链路：demo_image == alpine:3" "$ook"

    echo
    note "断言汇总：PASS=${PASS} FAIL=${FAIL}"
    [ "$FAIL" -eq 0 ] || exit 1
}

do_clean() {
    step "clean" "销毁一切（若 state 还在则先 destroy，再清后端与工作区）"
    if [ -d "$WORK" ]; then
        ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform destroy -auto-approve -input=false -no-color \
            -var "hold_seconds=1s" >/dev/null 2>&1 ) || true
    fi
    docker rm -f "$PG_NAME" >/dev/null 2>&1 || true
    rm -rf tmp
    local leftover=0
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -qE "tf08" && leftover=1 || true
    local lrc=0
    [ "$leftover" -eq 0 ] || lrc=1
    assert "零残留（无 tf08 容器，工作区已清）" "$lrc"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)     do_up ;;
        init)   do_init ;;
        demo)   do_demo ;;
        verify) do_verify ;;
        clean)  do_clean ;;
        all)    do_up; do_init; do_demo; do_verify; do_clean ;;
        *) echo "可用: up | init | demo | verify | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
