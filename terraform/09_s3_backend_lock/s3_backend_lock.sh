#!/usr/bin/env bash
# =============================================================================
# 09 · S3 backend + use_lockfile 真锁 — 主演示脚本
#
# 与项目 08（pg 会话锁）对照着跑，S3 系后端的锁行为一目了然：
#   [锁是数据]   锁 = 桶里的普通对象 <key>.tflock，cat 出来就是持锁者信息
#   [撞锁]       A 持锁窗口内 B apply → "Error acquiring the state lock"
#   [滞留]       SIGKILL A（对比 pg：连接断锁自动回收）→ 锁对象仍在桶里
#                → C 照样被拒 → 这就是 S3 系"锁卡死"事故原型
#   [真解]       force-unlock 删掉锁对象 → exists 变 404 → 这边它是真解
#                （对照 pg 后端的假成功——两种后端行为差异的核心考题）
#   [远程性]     杀掉 ObjStor 进程再拉起，state 完好——数据在对象存储，不在进程
#
# ./s3_backend_lock.sh up      起自家 ObjStor（宿主进程，S3 API :9200）
# ./s3_backend_lock.sh init    初始化 TF 工作区（S3 backend）
# ./s3_backend_lock.sh demo    锁生命周期五场景 + 断言
# ./s3_backend_lock.sh verify  终态断言（含重启远程性）
# ./s3_backend_lock.sh clean   销毁一切，零残留
# ./s3_backend_lock.sh all     上面五步一条龙
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

# provider 走仓库内置 filesystem mirror（scripts/tfrc.sh）——离线秒装
. "../../scripts/tfrc.sh"

OBJSTOR_SRC="$(cd "$PWD/../../.." && pwd)/objstor"   # 自家 ObjStor 仓库（labs/03 同款布局）
OBJSTOR_DATA="$PWD/tmp/objstor-data"
OBJSTOR_LOG="$PWD/tmp/objstor.log"
OBJSTOR_PID_FILE="$PWD/tmp/objstor.pid"
S3CLI="$PWD/scripts/s3_client.py"
EP="127.0.0.1:9200"
BUCKET="tfstate"
KEY="lab09/terraform.tfstate"
WORK="tmp/work"
PASS=0 FAIL=0
APID=""

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
s3()   { python3 "$S3CLI" "$@"; }

assert() {
    local desc="$1" rc="$2"
    if [ "$rc" -eq 0 ]; then
        PASS=$((PASS+1)); note "[ok]   $desc"
    else
        FAIL=$((FAIL+1)); note "[FAIL] $desc"
    fi
}

kill_A() {
    if [ -n "$APID" ] && kill -0 "$APID" 2>/dev/null; then
        pkill -9 -P "$APID" 2>/dev/null || true   # provider 插件子进程一起杀，防"诈尸"
        kill -9 "$APID" 2>/dev/null || true
    fi
}
trap kill_A EXIT

objstor_prepare() {
    rm -rf "$OBJSTOR_DATA" && mkdir -p "$OBJSTOR_DATA/data/config"
    # ⚠️ ObjStor 从进程 CWD 读硬编码相对路径 data/config/objstor.json
    # （labs/03 同款坑）——必须 cd 进专属目录启动
    OBJSTOR_DATA="$OBJSTOR_DATA" python3 - <<'PY2'
import json, os
data = os.environ["OBJSTOR_DATA"]
cfg = {
    "server": {"host": "0.0.0.0", "port": 9200, "s3_port": 9200, "enable_tls": False,
               "tls_cert": "", "tls_key": "", "max_request_size": 5368709120,
               "log_level": "info", "log_dir": "./logs"},
    "storage": {"data_dir": os.path.join(data, "data"),
                "pools": [{"id": "pool-001", "path": os.path.join(data, "pool"),
                           "capacity": 107374182400, "max_objects": 1000000,
                           "quota_enabled": False, "tier": "hot"}],
                "scheduler": {"strategy": "least_loaded", "rebalance_threshold": 0.2}},
    "ai": {"enabled": False, "api_endpoint": "", "api_key": "", "model": "",
           "max_tokens": 1024, "timeout_secs": 15, "auto_tag": False}
}
open(os.path.join(data, "data", "config", "objstor.json"), "w").write(json.dumps(cfg, indent=2))
PY2
}

objstor_launch() {
    local bin="$OBJSTOR_SRC/target/release/objstor"
    [ -x "$bin" ] || { echo "    [!] ObjStor 二进制缺失（需先在 $OBJSTOR_SRC 构建）" >&2; exit 1; }
    ( cd "$OBJSTOR_DATA" && OBJSTOR_DATA_DIR="$OBJSTOR_DATA" "$bin" >> "$OBJSTOR_LOG" 2>&1 & echo $! > "$OBJSTOR_PID_FILE" )
    local i=0
    until curl -fsS "http://$EP/health" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 30 ] && { echo "    [!] ObjStor 30s 未就绪（日志: $OBJSTOR_LOG）" >&2; exit 1; }
        sleep 1
    done
    # 种下与 versions.tf 一致的 minioadmin 凭据（已存在则忽略）
    curl -sf -X POST "http://$EP/api/v1/access-keys" \
        -H "Content-Type: application/json" \
        -d '{"access_key_id":"minioadmin","secret_key":"minioadmin"}' >/dev/null 2>&1 || true
}

# up 用：全新数据目录 + 启动
objstor_start() {
    objstor_prepare
    objstor_launch
}

objstor_stop() {
    if [ -f "$OBJSTOR_PID_FILE" ]; then
        kill "$(cat "$OBJSTOR_PID_FILE")" 2>/dev/null || true
        rm -f "$OBJSTOR_PID_FILE"
    fi
    # 兜底：清掉还占着 9200 的遗留实例（lab 03 偶有忘关的）
    local pid
    pid=$(lsof -tiTCP:9200 -sTCP:LISTEN 2>/dev/null | head -1)
    [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
}

do_up() {
    step "up" "起自家 ObjStor（宿主进程 S3 API :9200；接管 9200 上的遗留实例）"
    local old
    old=$(lsof -tiTCP:9200 -sTCP:LISTEN 2>/dev/null | head -1)
    [ -n "$old" ] && { note "结束 9200 上的旧实例（pid=${old}）"; kill "$old" 2>/dev/null || true; sleep 1; }
    objstor_start
    s3 mb "http://$EP" "$BUCKET" | sed 's/^/        /'
    note "[ok] ObjStor 就绪（bucket=${BUCKET}，数据目录 tmp/objstor-data）"
}

do_init() {
    step "init" "初始化 TF 工作区（S3 backend + use_lockfile；工作目录 ${WORK}）"
    mkdir -p "$WORK"
    cp configs/*.tf "$WORK/"
    local attempt rc=1 out
    for attempt in 1 2 3; do
        rc=0
        out=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform init -input=false -no-color ) 2>&1 ) || rc=$?
        echo "$out" | grep -E "Initializing|Terraform has been|Error|backend" | sed 's/^/        /'
        [ "$rc" -eq 0 ] && break
        note "[i] 第 ${attempt} 次 init 失败（后端握手预热竞态），2s 后重试……"
        sleep 2
    done
    [ "$rc" -eq 0 ] || { echo "    [!] init 三次均失败，检查 ObjStor 状态" >&2; exit 1; }
    note "[ok] backend = s3 @ http://${EP}/${BUCKET}/${KEY}（use_lockfile=true）"
}

do_demo() {
    step "demo" "场景一【撞锁】：A 持锁窗口内 B 强行 apply"
    [ -d "$WORK" ] || { echo "    [!] 工作区不存在——先跑 ./s3_backend_lock.sh init" >&2; exit 1; }
    cd "$WORK"
    TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=45s" > ../applyA.log 2>&1 &
    APID=$!
    disown "$APID" 2>/dev/null || true
    cd - >/dev/null
    note "A 已后台启动（pid=${APID}），等锁对象出现在桶里……"

    local i=0 st=""
    until st=$(s3 exists "http://$EP" "$BUCKET" "${KEY}.tflock") && [ "$st" = "200" ]; do
        i=$((i+1)); [ $i -gt 60 ] && { echo "    [!] 60s 内未见锁对象，A 日志：" >&2; tail -5 applyA.log >&2; exit 1; }
        sleep 1
    done
    note "锁对象 ${KEY}.tflock 已在桶里（HTTP ${st}）——锁是数据，cat 得出来："
    s3 cat "http://$EP" "$BUCKET" "${KEY}.tflock" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print('        ', {k: d[k] for k in ('ID','Operation','Who') if k in d})" 2>/dev/null || true
    local lok=1
    [ "$st" = "200" ] && lok=0
    assert "锁对象 <key>.tflock 在桶里可见（锁是数据，不是黑盒）" "$lok"

    local brc=0 berr
    berr=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=1s" ) 2>&1 ) || brc=$?
    local bok=1
    echo "$berr" | grep -q "Error acquiring the state lock" && bok=0
    assert "B 被拦且报错含 'Error acquiring the state lock'" "$bok"
    local LOCK_ID
    LOCK_ID=$(echo "$berr" | grep -A1 "Lock Info" | grep "ID:" | awk '{print $2}' | head -1)
    note "锁信息已随报错吐出：Lock ID = ${LOCK_ID:-<未取到>}"

    step "demo" "场景二【滞留】：SIGKILL A——pg 里连接断锁自动回收，这边呢？"
    kill_A
    note "A 已被 SIGKILL（对比项目 08：pg 这时锁已自动回收）"
    sleep 2
    st=$(s3 exists "http://$EP" "$BUCKET" "${KEY}.tflock")
    local sok=1
    [ "$st" = "200" ] && sok=0
    assert "持锁者死亡后锁对象仍在桶里（granted 与否无关——锁是数据）" "$sok"
    local crc=0
    ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=1s" >/dev/null 2>&1 ) || crc=$?
    local cok=1
    [ "$crc" -ne 0 ] && cok=0
    assert "C 照样被拒——这就是 S3 系'锁卡死'事故原型" "$cok"

    step "demo" "场景三【真解】：force-unlock 删掉锁对象（这边它是真解）"
    local fu_out fu_rc=0
    if [ -n "${LOCK_ID:-}" ]; then
        fu_out=$( ( cd "$WORK" && terraform force-unlock -force "$LOCK_ID" ) 2>&1 ) || fu_rc=$?
        echo "$fu_out" | tail -4 | sed 's/^/        | /'
        note "force-unlock 退出码 ${fu_rc}——对照项目 08 的假成功，看锁对象还在不在："
    fi
    sleep 1
    st=$(s3 exists "http://$EP" "$BUCKET" "${KEY}.tflock")
    local fok=1
    [ "$st" = "404" ] && fok=0
    assert "force-unlock 后锁对象消失（exists=${st}）——S3 系上它是真解" "$fok"

    step "demo" "恢复：D 正常 apply"
    local drc=0 dout
    dout=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform apply -auto-approve -input=false -no-color \
        -var "hold_seconds=1s" ) 2>&1 ) || drc=$?
    echo "$dout" | tail -3 | sed 's/^/        /'
    assert "锁解除后 D apply 成功" "$drc"

    echo
    note "断言汇总：PASS=${PASS} FAIL=${FAIL}"
    [ "$FAIL" -eq 0 ] || exit 1
}

# plan 终态检查：偶发后端抖动会崩，崩了还会留滞留锁（锁是数据——进程死了
# 数据还在）。按"发现滞留锁 → force-unlock → 重试"的生产剧本自愈，两次以内必稳
plan_no_changes() {
    local attempt rc=0 out lid
    for attempt in 1 2; do
        rc=0
        out=$( ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform plan -input=false -no-color -var "hold_seconds=1s" ) 2>&1 ) || rc=$?
        if [ $rc -ne 0 ] && echo "$out" | grep -q "Error acquiring the state lock"; then
            lid=$(echo "$out" | grep -A1 "Lock Info" | grep "ID:" | awk '{print $2}' | head -1)
            note "plan 撞上滞留锁（${lid:-?}）——持有者已死，按剧本 force-unlock 后重试"
            [ -n "${lid:-}" ] && ( cd "$WORK" && terraform force-unlock -force "$lid" >/dev/null 2>&1 ) || true
            continue
        fi
        [ $rc -eq 0 ] && break
        note "[i] 第 ${attempt} 次 plan 失败（后端抖动），2s 后重试……"
        sleep 2
    done
    echo "$out" | grep -q "No changes" && return 0 || return 1
}

do_verify() {
    step "verify" "终态断言：plan 干净 / state 落桶 / 重启远程性"
    local prc=1
    plan_no_changes && prc=0 || prc=1
    assert "terraform plan → No changes（终态收敛）" "$prc"

    local src=0
    ( cd "$WORK" && terraform state list ) 2>/dev/null | grep -q "docker_image.demo" || src=$?
    assert "state 里有 docker_image.demo" "$src"

    local body
    body=$(s3 cat "http://$EP" "$BUCKET" "$KEY")
    local vok=1
    [ -n "$body" ] && vok=0
    assert "state 正文已落桶（cat ${KEY} 非空）" "$vok"

    step "verify" "重启远程性：杀掉 ObjStor 进程再拉起，state 完好"
    objstor_stop
    sleep 1
    objstor_launch   # 只拉起不 prepare：数据目录原封不动，正是要证明"数据不在进程里"
    note "ObjStor 已重启（数据目录未动）"
    local rrc=1
    plan_no_changes && rrc=0 || rrc=1
    assert "重启后 plan 仍 No changes——数据在对象存储，不在进程里" "$rrc"

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
    step "clean" "销毁一切（destroy + 清桶内本实验对象 + 停 ObjStor + 清工作区）"
    if [ -d "$WORK" ]; then
        ( cd "$WORK" && TF_IN_AUTOMATION=1 terraform destroy -auto-approve -input=false -no-color \
            -var "hold_seconds=1s" >/dev/null 2>&1 ) || true
    fi
    s3 rm "http://$EP" "$BUCKET" "lab09" >/dev/null 2>&1 || true
    objstor_stop
    rm -rf tmp
    local lrc=0
    lsof -tiTCP:9200 -sTCP:LISTEN >/dev/null 2>&1 && lrc=1
    assert "零残留（9200 无监听，桶内 lab09 前缀已清，工作区已删）" "$lrc"
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
