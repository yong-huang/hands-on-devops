#!/usr/bin/env bash
# =============================================================================
# 09 · 自定义 sourcetype 解析 — 主演示脚本
#
# 两种"非标准"数据各自配 props.conf：多行异常栈（切分不丢不并）与 CSV
# 结构化（INDEXED_EXTRACTIONS 索引时字段）。四条断言：栈事件数对账、
# _time 对照、REPORT 字段 null=0、CSV 行数与字段。
#
# ./spl_parse.sh up       索引器就绪 + 建 parse_demo 索引
# ./spl_parse.sh deploy   部署 props/transforms + 重启 + 产生测试数据
# ./spl_parse.sh ingest   oneshot 双文件入库 + 检索可见轮询
# ./spl_parse.sh verify   四条断言（多行/时间/字段/CSV）
# ./spl_parse.sh clean    删索引 + 删配置 + 重启归零
# ./spl_parse.sh all      up → deploy → ingest → verify → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPLD="https://localhost:28089"
LAB01="../01_splunk_deploy"
IDX="parse_demo"

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
    step up "索引器就绪 + 建 parse_demo 索引"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        wait_splunk "冷启动"
    else
        note "[ok] splunk-deploy 已在运行"
    fi
    local code
    code=$(curl -sk -u "admin:${SPLUNK_PASSWORD}" -o /dev/null -w '%{http_code}' "$SPLD/services/data/indexes/$IDX")
    if [ "$code" = "200" ]; then note "[ok] 索引 $IDX 已存在"; else
        docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add index "$IDX" \
            -auth "admin:${SPLUNK_PASSWORD}" >/dev/null && note "[ok] 索引 $IDX 已创建"
    fi
}

do_deploy() {
    load_env
    step deploy "部署 props/transforms + 重启 + 产生测试数据"
    # 幂等：先清旧配置再部署
    docker exec -u root splunk-deploy sh -c "rm -f /opt/splunk/etc/system/local/props.conf /opt/splunk/etc/system/local/transforms.conf" || true
    docker cp configs/props.conf      splunk-deploy:/opt/splunk/etc/system/local/props.conf
    docker cp configs/transforms.conf splunk-deploy:/opt/splunk/etc/system/local/transforms.conf
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "配置生效重启"
    mkdir -p tmp
    python3 gen_testdata.py --out tmp
    note "[ok] 测试数据已生成 tmp/stack.log + tmp/rows.csv"
}

do_ingest() {
    load_env
    step ingest "双文件 oneshot 入库 + 检索可见轮询"
    mkdir -p tmp
    docker cp tmp/stack.log splunk-deploy:/tmp/stack.log
    docker cp tmp/rows.csv  splunk-deploy:/tmp/rows.csv
    docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add oneshot /tmp/stack.log \
        -index "$IDX" -sourcetype splk_stack -host svc-node \
        -auth "admin:${SPLUNK_PASSWORD}" >/dev/null || fail "stack.log 入库失败"
    docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add oneshot /tmp/rows.csv \
        -index "$IDX" -sourcetype splk_csv_lab -host csv-node \
        -auth "admin:${SPLUNK_PASSWORD}" >/dev/null || fail "rows.csv 入库失败"
    note "[ok] 双文件已入库（sourcetype=splk_stack / splk_csv_lab）"
    # 检索可见性异步收敛（lab 05 同款坑）——轮询目标查询本身
    local i=0 n=0
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "120s 内栈事件未全部可见（当前 ${n}）"
        n=$(qcount "index=$IDX sourcetype=splk_stack | stats count")
        [ "$n" -eq 100 ] 2>/dev/null && { note "[ok] 100 条栈事件全部可见（约 $((i*5))s）"; break; }
        sleep 5
    done
}

do_verify() {
    load_env
    step verify "四条断言"
    # A：多行切分对账（100 事件不丢不并——行数远多于 100，切错就数不对）
    local stack csv
    stack=$(qcount "index=$IDX sourcetype=splk_stack | stats count")
    [ "$stack" = "100" ] || fail "断言 A：栈事件 ${stack} ≠ 100"
    ok "断言 A：多行栈切分 100 事件（不丢不并）"
    # B：_time 与产生器时间范围对照（±3s）
    python3 - <<'PYEOF'
import json, subprocess, os

def q(spl):
    s = spl if spl.startswith("|") else "search " + spl
    r = subprocess.run(["curl", "-sk", "-u", f"admin:{os.environ['SPLUNK_PASSWORD']}",
                        "https://localhost:28089/services/search/jobs",
                        "--data-urlencode", f"search={s}",
                        "--data-urlencode", "exec_mode=oneshot",
                        "--data-urlencode", "output_mode=json",
                        "--data-urlencode", "earliest_time=0"],
                       capture_output=True, text=True, check=True)
    return json.loads(r.stdout).get("results", [])

prod = json.load(open("tmp/prod.json"))
r = q("index=parse_demo sourcetype=splk_stack | stats min(_time) as mn, max(_time) as mx")[0]
assert abs(float(r["mn"]) - prod["base_ts"]) <= 3 and abs(float(r["mx"]) - prod["last_ts"]) <= 3, r
rc = q("index=parse_demo sourcetype=splk_csv_lab | stats min(_time) as mn")[0]
assert abs(float(rc["mn"]) - prod["base_ts"]) <= 3, rc
print("        ✅ 断言 B：_time 与产生器时间范围一致（栈与 CSV 双源 ±3s）")
# C：REPORT 字段 null=0
r = q("index=parse_demo sourcetype=splk_stack | stats count as total, count(eval(isnull(level))) as nl, count(eval(isnull(svc))) as ns")[0]
assert int(r["nl"]) == 0 and int(r["ns"]) == 0, r
print(f"        ✅ 断言 C：REPORT 字段 level/svc null=0（{r['total']} 事件全覆盖）")
# D：CSV 行数与字段
r = q("index=parse_demo sourcetype=splk_csv_lab | stats count as total, dc(user) as users")[0]
assert int(r["total"]) == 50 and int(r["users"]) >= 5, r
print(f"        ✅ 断言 D：CSV 50 行对账（INDEXED_EXTRACTIONS 字段可查，user {r['users']} 种）")
PYEOF
    ok "断言 B/C/D 全过（明细见上）"
}

do_clean() {
    load_env
    step clean "删索引 + 删配置 + 重启归零"
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPLD/services/data/indexes/$IDX" >/dev/null \
        && note "[ok] 索引 $IDX 已删除"
    docker exec -u root splunk-deploy sh -c "rm -f /opt/splunk/etc/system/local/props.conf /opt/splunk/etc/system/local/transforms.conf"
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "清理重启"
    rm -rf tmp
    ok "解析配置与数据零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)     do_up ;;
        deploy) do_deploy ;;
        ingest) do_ingest ;;
        verify) do_verify ;;
        clean)  do_clean ;;
        all)    do_up; do_deploy; do_ingest; do_verify; do_clean ;;
        *) echo "可用: up | deploy | ingest | verify | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
