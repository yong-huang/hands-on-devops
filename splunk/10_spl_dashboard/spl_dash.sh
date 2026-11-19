#!/usr/bin/env bash
# =============================================================================
# 10 · 运维仪表盘 — 主演示脚本
#
# dashboard.json（Dashboard Studio 定义）是唯一事实源：脚本从中提取 4 个
# panel 的查询，经 REST 逐条执行并断言行数 > 0；同时校验结构与自动刷新配置。
# 注意：本实验不向 Splunk 导入仪表盘——Studio JSON 在 UI 一次点击即可导入，
# 验收聚焦"panel 查询真实有数据"。
#
# ./spl_dash.sh up      确保教程数据就绪（复用 lab 02）
# ./spl_dash.sh verify  从 dashboard.json 提取 4 查询 → REST 执行 → 断言
# ./spl_dash.sh clean   清 tmp
# ./spl_dash.sh all     up → verify → clean
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

SPLD="https://localhost:28089"
LAB01="../01_splunk_deploy"
LAB02="../02_tutorial_data"

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

do_up() {
    load_env
    step up "确保教程数据就绪"
    if ! curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version'; then
        docker compose -f "$LAB01/docker-compose.yml" up -d 2>&1 | sed 's/^/        /'
        local i=0
        while :; do
            i=$((i+1)); [ $i -gt 84 ] && fail "splunk 420s 未就绪"
            curl -sk -u "admin:${SPLUNK_PASSWORD}" "$SPLD/services/server/info" 2>/dev/null | grep -q 'version' \
                && { note "[ok] splunkd 就绪"; break; }
            sleep 5
        done
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

do_verify() {
    load_env
    step verify "dashboard.json → 提取 4 查询 → REST 断言"
    mkdir -p tmp
    # 结构断言：4 数据源 / 4 可视化 / 布局 / 自动刷新
    python3 - <<'PYEOF'
import json
d = json.load(open("dashboard.json", encoding="utf-8"))
defn = d["definition"]
ds, viz = defn["dataSources"], defn["visualizations"]
assert len(ds) == 4 and len(viz) == 4, (len(ds), len(viz))
assert defn["layout"]["type"] == "absolute" and len(defn["layout"]["structure"]) == 4
refresh = [o["options"].get("refresh") for o in ds.values()]
assert all(r == "30s" for r in refresh), refresh
print(f"        ✅ 结构断言：4 数据源 / 4 可视化 / absolute 布局 / 自动刷新 30s 全配置")
PYEOF
    ok "结构断言通过（含 autoRefresh 语义的 refresh 配置）"
    # panel 断言：逐条执行，行数 > 0
    python3 - <<'PYEOF'
import json, subprocess, os

d = json.load(open("dashboard.json", encoding="utf-8"))
ds = d["definition"]["dataSources"]
titles = {k: v["title"] for k, v in d["definition"]["visualizations"].items()}

def run(spl):
    s = spl if spl.startswith("|") else "search " + spl
    r = subprocess.run(["curl", "-sk", "-u", f"admin:{os.environ['SPLUNK_PASSWORD']}",
                        "https://localhost:28089/services/search/jobs",
                        "--data-urlencode", f"search={s}",
                        "--data-urlencode", "exec_mode=oneshot",
                        "--data-urlencode", "output_mode=json",
                        "--data-urlencode", "earliest_time=0"],
                       capture_output=True, text=True, check=True)
    return json.loads(r.stdout)

for vk, vv in d["definition"]["visualizations"].items():
    dsid = vv["dataSources"]["primary"]
    q = ds[dsid]["options"]["query"]
    res = run(q)
    bad = [m["text"] for m in res.get("messages", []) if m.get("type") in ("ERROR", "FATAL")]
    assert not bad, f"{vk}: {bad}"
    rows = len(res.get("results", []))
    print(f"        ✅ panel[{vk}] {vv['title']} —— {rows} 行")
    assert rows > 0, f"{vk} 返回 0 行"
print("        ✅ 4/4 panel 查询全部有数据")
PYEOF
    ok "panel 断言通过（4 查询经 REST 全部 >0 行）"
}

do_clean() {
    step clean "清 tmp"
    rm -rf tmp
    ok "tmp 已清；dashboard.json 为静态产物，无需向 Splunk 清理"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        up)     do_up ;;
        verify) do_verify ;;
        clean)  do_clean ;;
        all)    do_up; do_verify; do_clean ;;
        *) echo "可用: up | verify | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
