#!/usr/bin/env bash
# =============================================================================
# 02 · 教程数据入库与数据四元组认知 — 主演示脚本
#
# 下载官方 tutorialdata.zip（Buttercup Games 数据集）→ 解包 → 按
# index/sourcetype/source/host 四元组逐文件入库 → 三条验收 SPL 断言
# （总量 ≥1000 / sourcetype ≥3 种 / host ≥2 台）→ 清理。
#
# ./tutorial_data.sh up         确保 lab 01 的 splunk 实例在跑（没有就拉起）
# ./tutorial_data.sh download   下载教程 zip（UA 403 坑：必须带完整浏览器 UA）
# ./tutorial_data.sh ingest     建索引 + 逐文件 oneshot 入库（四元组显式指定）
# ./tutorial_data.sh observe    三条验收 SPL 断言 + 默认字段观察
# ./tutorial_data.sh clean      删 tutorial 索引 + 删 tmp（不动 splunk 实例）
# ./tutorial_data.sh all        up → download → ingest → observe → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPL="https://localhost:28089"
LAB01="../01_splunk_deploy"
ZIP="tmp/tutorialdata.zip"
UA="Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
# 四元组入库映射：相对路径 | sourcetype | host（source 用相对路径本身）
# access=Web 访问日志；secure=sshd 认证日志（raw 里自带主机名 mailsv1）；
# vendor_sales=支付供应商流水（host 标 vendor001，教学约定）
MAP=(
    "www1/access.log|access_combined_wcookie|www1"
    "www2/access.log|access_combined_wcookie|www2"
    "www3/access.log|access_combined_wcookie|www3"
    "www1/secure.log|linux_secure|www1"
    "www2/secure.log|linux_secure|www2"
    "www3/secure.log|linux_secure|www3"
    "mailsv/secure.log|linux_secure|mailsv1"
    "vendor_sales/vendor_sales.log|vendor_sales|vendor001"
)

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

load_env() {
    [ -f "$LAB01/.env" ] || fail "缺 $LAB01/.env——先做 lab 01（cp .env.example .env）"
    # shellcheck disable=SC1090
    source "$LAB01/.env"
    [ -n "${SPLUNK_PASSWORD:-}" ] || fail "SPLUNK_PASSWORD 为空"
}

# REST oneshot 搜索：REST 的 search 参数必须显式以 `search ` 开头（lab 01 踩过），
# 但生成型命令（|eval / tstats / |stats...）不能加前缀——`search | tstats` 是
# 非法语法，会静默返回空结果。按首字符判断是否补前缀
spl_search() {  # <SPL> → 结果 JSON
    local spl="$1" pfx
    case "$spl" in
        "|"*|tstats*|search*) pfx="" ;;
        *) pfx="search " ;;
    esac
    curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/search/jobs" \
        --data-urlencode "search=${pfx}${spl}" \
        --data-urlencode "exec_mode=oneshot" \
        --data-urlencode "output_mode=json" \
        --data-urlencode "earliest_time=0"
}

qcount() {  # <SPL> → 首行首列的值（列名随 SPL 而变：count / dc(host) / ...）
    spl_search "$1" | python3 -c "import json,sys; d=json.load(sys.stdin); print(list(d['results'][0].values())[0] if d.get('results') else 0)"
}

# 入库后有秒级检索延迟——轮询到目标值出现（≤120s），搜到但不达目标立即报
wait_at_least() {  # <SPL> <目标值> <说明>
    local i=0 c=0
    while :; do
        i=$((i+1)); [ $i -gt 24 ] && fail "$3：120s 后计数=$c，未达 $2"
        c=$(qcount "$1")
        [ "$c" -ge "$2" ] 2>/dev/null && { echo "$c"; return 0; }
        sleep 5
    done
}

do_up() {
    load_env
    step up "确保 lab 01 的 splunk 实例在跑"
    if curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version'; then
        note "[ok] splunk-deploy 已在运行，直接复用"
    else
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        local i=0
        while :; do
            i=$((i+1)); [ $i -gt 84 ] && fail "splunk 420s 未就绪"
            curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPL/services/server/info" 2>/dev/null | grep -q 'version' \
                && { note "[ok] splunkd 就绪（约 $((i*5))s）"; break; }
            sleep 5
        done
    fi
}

do_download() {
    step download "下载 tutorialdata.zip（完整浏览器 UA；curl 默认 UA 实测 403）"
    mkdir -p tmp
    # 快路径：容器内走 OrbStack 代理（VM 出口实测秒下）；宿主直连被限速 ~1.5KB/s。
    # 注意传参写法：entrypoint 已经是 sh，追加的命令必须以 -c 开头；
    # 再写一层 "sh -c" 会变成 sh 执行 sh 二进制，报 cannot execute binary file
    docker run --rm --entrypoint sh -v "$PWD/tmp:/out" splunk/splunk:9.4 \
        -c "curl -sL --max-time 120 -x http://proxy.orb.internal:8305 -A '$UA' -o /out/tutorialdata.zip https://docs.splunk.com/images/Tutorial/tutorialdata.zip || exit 1" \
        || fail "容器内下载失败"
    # 完整性：PK 魔数 + 体积 >1.5MB。注意 HEAD 报的 Content-Length（1955044）
    # 是过期的——真实文件 1955097 字节，别按 HEAD 值断言精确大小（实测踩过）
    local sz; sz=$(stat -f%z "$ZIP")
    [ "$(head -c 2 "$ZIP")" = "PK" ] || fail "下载产物不是 zip（PK 魔数缺失）"
    [ "$sz" -gt 1500000 ] || fail "zip 只有 ${sz} 字节，疑似截断"
    note "[ok] ${sz} 字节，zip 完整"
}

do_ingest() {
    load_env
    step ingest "解包 + 建 tutorial 索引 + 逐文件 oneshot（四元组显式指定）"
    rm -rf tmp/tut && mkdir -p tmp/tut
    unzip -qo "$ZIP" -d tmp/tut
    docker cp tmp/tut splunk-deploy:/tmp/tut
    # 索引存在性：REST GET 404 才创建（等价声明式写法见 configs/tutorial_indexes.conf）
    local code; code=$(curl -sk -u "admin:${SPLUNK_PASSWORD}" -o /dev/null -w '%{http_code}' "$SPL/services/data/indexes/tutorial")
    if [ "$code" = "200" ]; then
        note "[ok] 索引 tutorial 已存在"
    else
        docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add index tutorial \
            -auth "admin:${SPLUNK_PASSWORD}" >/dev/null && note "[ok] 索引 tutorial 已创建"
    fi
    local entry rel st host
    for entry in "${MAP[@]}"; do
        rel="${entry%%|*}"; st="$(echo "$entry" | cut -d'|' -f2)"; host="${entry##*|}"
        note "oneshot ${rel} → sourcetype=${st} host=${host}"
        # 参数名注意：add oneshot 用 -hostname/-rename-source（-host/-source 是
        # add monitor 的参数，混用报 Only one "name" parameter can be specified）
        docker exec -u splunk splunk-deploy /opt/splunk/bin/splunk add oneshot "/tmp/tut/${rel}" \
            -index tutorial -sourcetype "$st" -hostname "$host" -rename-source "$rel" \
            -auth "admin:${SPLUNK_PASSWORD}" >/dev/null \
            || fail "oneshot ${rel} 失败"
        local c; c=$(wait_at_least "index=tutorial source=\"${rel}\" | stats count" 1 "${rel} 可检索")
        note "  → ${c} 条已可检索"
    done
}

do_observe() {
    load_env
    step observe "四元组全景表 + 三条验收断言"
    echo "        ── sourcetype × host 分布（| tstats 走 tsidx 元数据，不碰 raw）──"
    spl_search "| tstats count where index=tutorial by sourcetype, host" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('results', []):
    print(f\"        {r.get('sourcetype',''):<24} host={r.get('host',''):<12} count={r.get('count','')}\")"
    echo "        ── 默认字段对照（事件时间 vs 入库时间）──"
    # 转换型命令（eval/stats）开头 = 零输入事件 = 空结果——必须以 index= 起头
    spl_search "index=tutorial | eval lag_s=_indextime-_time | stats max(lag_s) as lag_max" \
        | python3 -c "
import json, sys
d = json.load(sys.stdin)
r = d.get('results', [])
print(f\"        _indextime-_time 最大滞后: {r[0].get('lag_max','?')} 秒（事件时间早于入库时间越多，滞后越大）\" if r else '')"
    local total sts hosts
    total=$(qcount "index=tutorial | stats count")
    [ "$total" -ge 1000 ] 2>/dev/null || fail "断言1 总量=$total < 1000"
    ok "断言1：index=tutorial 总事件 = ${total}（≥1000）"
    sts=$(spl_search "| tstats count where index=tutorial by sourcetype" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('results',[])))")
    [ "$sts" -ge 3 ] 2>/dev/null || fail "断言2 sourcetype 种类=$sts < 3"
    ok "断言2：sourcetype ${sts} 种（≥3）"
    hosts=$(qcount "index=tutorial | stats dc(host)")
    [ "$hosts" -ge 2 ] 2>/dev/null || fail "断言3 host 台数=$hosts < 2"
    ok "断言3：host ${hosts} 台（≥2）"
}

do_clean() {
    load_env
    step clean "删 tutorial 索引 + 删 tmp（splunk 实例归 lab 01 管，不停机）"
    curl -sk -u "admin:${SPLUNK_PASSWORD}" -X DELETE "$SPL/services/data/indexes/tutorial" \
        | grep -q message && note "[ok] 索引 tutorial 已删除"
    rm -rf tmp
    local c; c=$(qcount "index=tutorial | stats count" || echo 0)
    [ "$c" = "0" ] && ok "残留事件 = 0，回到实验前状态" || note "索引删除后事件残留 ${c}（可能需数秒收敛）"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)       do_up ;;
        download) do_download ;;
        ingest)   do_ingest ;;
        observe)  do_observe ;;
        clean)    do_clean ;;
        all)      do_up; do_download; do_ingest; do_observe; do_clean ;;
        *) echo "可用: up | download | ingest | observe | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
