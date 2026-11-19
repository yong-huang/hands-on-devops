#!/usr/bin/env bash
# =============================================================================
# 05 · 字段工程 — 主演示脚本
#
# 三条提取途径与两层验证：
#   ① rex 内联提取 → 与出厂内置字段逐条对照（≥19/20 一致）
#   ② props.conf/transforms.conf REPORT 持久抽取 → 自定义 sourcetype
#      splk_access_lab 搜素时字段自动出现（不写 rex）
#   ③ REPORT 字段值 → 与 Python 独立解析对照（20/20 一致）
#
# ./spl_fields.sh up       确保 splunk + tutorial 数据就绪（复用 lab 02）
# ./spl_fields.sh rex      rex 提取 vs 内置字段对照断言
# ./spl_fields.sh persist  部署 props/transforms + 建 lab 索引 + 样本入库
# ./spl_fields.sh verify   REPORT 字段自动出现断言 + Python 独立对照
# ./spl_fields.sh clean    删 lab 索引 + 删容器内配置 + 重启归零
# ./spl_fields.sh all      up → rex → persist → verify → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPL="https://localhost:28089"
LAB01="../01_splunk_deploy"
LAB02="../02_tutorial_data"
LAB_ST="splk_access_lab"
LAB_IDX="splk_fields_lab"
# rex 提取（命名捕获，字段名加 rex_ 前缀避免与内置字段冲突）；
# 单引号防 shell 吃反斜杠，\" 是 SPL 双引号字符串内部的引号转义
REX_SPL='rex field=_raw "^(?P<rex_clientip>\S+) \S+ \S+ \[(?P<rex_ts>[^\]]+)\] \"(?P<rex_method>\S+) (?P<rex_uri>\S+)[^\"]*\" (?P<rex_status>\d+) (?P<rex_bytes>\d+)"'

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
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/search/jobs" \
        --data-urlencode "search=${pfx}${s}" \
        --data-urlencode "exec_mode=oneshot" \
        --data-urlencode "output_mode=json" \
        --data-urlencode "earliest_time=0"
}

qcount() {
    spl_search "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else 0)"
}

wait_splunk() {
    local tag="$1" i=0
    note "等待 splunkd 就绪（${tag}）..."
    while :; do
        i=$((i+1)); [ $i -gt 84 ] && fail "$tag 420s 未就绪"
        curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version' \
            && { note "[ok] 就绪（约 $((i*5))s）"; return 0; }
        sleep 5
    done
}

do_up() {
    load_env
    step up "确保 splunk 在跑 + tutorial 数据就绪"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        wait_splunk "冷启动"
    else
        note "[ok] splunk-deploy 已在运行"
    fi
    local total
    total=$(qcount "index=tutorial | stats count")
    if [ "$total" -ge 1000 ] 2>/dev/null; then
        note "[ok] tutorial 数据就绪（${total} 条）"
    else
        note "tutorial 数据不足 → 复用 lab 02 补灌"
        "$LAB02/tutorial_data.sh" download 2>&1 | sed 's/^/        /'
        "$LAB02/tutorial_data.sh" ingest  2>&1 | sed 's/^/        /'
    fi
}

do_rex() {
    load_env
    step rex "rex 内联提取 vs 出厂内置字段（同事件对照，≥19/20）"
    note "── rex 速查演示：从 _raw 提取 5 个字段（样例 3 条）"
    spl_search "index=tutorial sourcetype=access_combined_wcookie | head 3 | ${REX_SPL} | table rex_clientip, rex_method, rex_uri, rex_status, rex_bytes" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('results', []):
    print('        ' + '  '.join(f'{k}={v}' for k, v in r.items()))"
    note "── 正确率断言：rex_* 与出厂 clientip/status/bytes 同事件比对"
    local result verdict
    result=$(spl_search "index=tutorial sourcetype=access_combined_wcookie | head 20 | ${REX_SPL} | eval ok=if(rex_clientip==clientip AND rex_status==status AND rex_bytes==bytes,1,0) | stats sum(ok) as matched, count as total")
    verdict=$(printf '%s' "$result" | python3 -c "
import json, sys
d = json.load(sys.stdin)
bad = [m['text'] for m in d.get('messages', []) if m.get('type') in ('ERROR', 'FATAL')]
if bad:
    print('FAIL|' + bad[0][:100])
else:
    r = d['results'][0]
    print(f\"OK|{r.get('matched','0')}/{r.get('total','0')}\")")
    [[ "$verdict" == OK* ]] || fail "rex 对照查询失败：${verdict#FAIL|}"
    local matched="${verdict#OK|}"; matched="${matched%%/*}"; local total="${verdict##*/}"
    [ "$matched" -ge 19 ] 2>/dev/null || fail "rex 正确率 ${matched}/${total} < 19/20"
    ok "rex 提取正确率 ${matched}/${total}（≥19/20，参照=出厂内置解析）"
}

do_persist() {
    load_env
    step persist "部署 props/transforms → 建 lab 索引 → 50 条样本入库"
    # 配置进容器 system/local 后必须重启才生效（配置只在启动时读）
    docker cp configs/props.conf      splunk-deploy:/opt/splunk/etc/system/local/props.conf
    docker cp configs/transforms.conf splunk-deploy:/opt/splunk/etc/system/local/transforms.conf
    note "[ok] props.conf / transforms.conf 已进容器 system/local"
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "配置生效重启"
    # 独立 lab 索引：先删旧再建新——保证重复跑 all 时样本不翻倍（幂等）
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPL/services/data/indexes/$LAB_IDX" >/dev/null 2>&1 || true
    docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add index "$LAB_IDX" \
        -auth "admin:${SPLUNK_PASSWORD}" >/dev/null && note "[ok] 索引 $LAB_IDX 已重建"
    # 样本直接取自 tutorial 的 _raw（20 行）——不依赖 lab 02 的 zip 文件
    mkdir -p tmp
    spl_search "index=tutorial sourcetype=access_combined_wcookie | head 20 | table _raw" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
lines = [r['_raw'] for r in d.get('results', [])]
open('tmp/sample.log', 'w', encoding='utf-8').write('\n'.join(lines) + '\n')
print(f'        [ok] 样本 {len(lines)} 行已落盘 tmp/sample.log')"
    docker cp tmp/sample.log splunk-deploy:/tmp/sample.log
    # oneshot 时显式指定自定义 sourcetype——REPORT 就是在它身上生效
    docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add oneshot /tmp/sample.log \
        -index "$LAB_IDX" -sourcetype "$LAB_ST" -hostname www1 \
        -auth "admin:${SPLUNK_PASSWORD}" >/dev/null \
        || fail "样本 oneshot 失败"
    note "[ok] 20 行样本已按 sourcetype=$LAB_ST 入库 index=$LAB_IDX"
}

do_verify() {
    load_env
    step verify "REPORT 字段自动出现 + Python 独立对照（20/20）"
    mkdir -p tmp
    # 检索可见性异步收敛：count 查到 20 不代表下一次查询能看到全部
    # （实测踩过：count=20 → table 只回 1 行）——直接轮询目标查询本身
    local rows_json i=0 n
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "样本 120s 内未全部可见"
        rows_json=$(spl_search "index=$LAB_IDX sourcetype=$LAB_ST | table _raw, clientip, method, uri, status, bytes, referrer")
        n=$(printf '%s' "$rows_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('results',[])))")
        [ "$n" -eq 20 ] && { note "[ok] 样本 20 条全部可见"; break; }
        sleep 5
    done
    printf '%s' "$rows_json" > tmp/rows.json
    # 断言 A：不写 rex，REPORT 提取的字段直接可查（只打印提取字段，_raw 太长）
    python3 -c "
import json, sys
d = json.load(open('tmp/rows.json', encoding='utf-8'))
rows = d['results']
missing = [k for k in ('clientip', 'method', 'uri', 'status', 'bytes') if not rows[0].get(k)]
if missing:
    print('        ❌ 字段缺失: ' + ','.join(missing)); sys.exit(1)
keys = ('clientip', 'method', 'uri', 'status', 'bytes', 'referrer')
for r in rows[:3]:
    print('        ' + '  '.join(f'{k}={r[k]}' for k in keys))"
    ok "断言 A：REPORT 提取的字段搜索时自动出现（未写任何 rex）"
    # 断言 B：字段值与 Python 独立解析逐条一致
    python3 -c "
import json, re, sys
rows = json.load(open('tmp/rows.json', encoding='utf-8'))['results']
ref = {}
LINE_RE = re.compile(r'^(\S+) \S+ \S+ \[[^\]]+\] \"(\S+) [^\"]*\" (\d+) (\d+) ')
for line in open('tmp/sample.log', encoding='utf-8'):
    m = LINE_RE.match(line.rstrip('\n'))
    if m:
        ref[line.rstrip('\n')] = (m.group(1), m.group(2), m.group(3), m.group(4))
ok_n = sum(1 for r in rows
           if r.get('_raw') in ref
           and ref[r['_raw']] == (r.get('clientip'), r.get('method'), r.get('status'), r.get('bytes')))
print(f'        Python 独立对照：{ok_n}/{len(rows)} 条四字段完全一致')
assert ok_n == len(rows) == 20, f'对照不齐：{ok_n}/{len(rows)}'" \
        && ok "断言 B：REPORT 字段值与 Python 独立解析 20/20 一致" \
        || fail "断言 B 超差（明细见上）"
}

do_clean() {
    load_env
    step clean "删 lab 索引 + 删容器内配置 + 重启归零"
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPL/services/data/indexes/$LAB_IDX" >/dev/null \
        && note "[ok] 索引 $LAB_IDX 已删除"
    # -u root：默认 exec 用户是 ansible(999)，删不了 splunk 属主的配置（lab 01 同款坑）
    docker exec -u root splunk-deploy rm -f /opt/splunk/etc/system/local/props.conf \
        /opt/splunk/etc/system/local/transforms.conf
    docker compose -f "$LAB01/docker-compose.yml" restart 2>&1 | sed 's/^/        /'
    wait_splunk "清理重启"
    rm -rf tmp
    ok "配置与数据零残留（出厂解析不受影响）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)      do_up ;;
        rex)     do_rex ;;
        persist) do_persist ;;
        verify)  do_verify ;;
        clean)   do_clean ;;
        all)     do_up; do_rex; do_persist; do_verify; do_clean ;;
        *) echo "可用: up | rex | persist | verify | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
