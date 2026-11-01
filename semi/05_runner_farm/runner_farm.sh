#!/usr/bin/env bash
# semi/05_runner_farm · Runner 注册与标签资源池
# 用法：./runner_farm.sh up | verify | status | clean
#   up     签发 glrt 令牌 → 两个 runner 容器（eda/fpga）→ runner-lab 靶场流水线
#   verify 清单验收：① job 按标签落到指定 runner ② concurrent=2 的第 3 个 job 严格排队
#   status runner 在线状态与容器资源
#   clean  删 runner（API+容器）与靶场项目
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
IMG="docker.m.daocloud.io/gitlab/gitlab-runner:latest"   # daocloud 实测比 1ms 稳（1ms 大层爱断流）
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }

api() {
    # 带重试的 GET：OrbStack 偶发瞬时空响应（实测过一次），空了重试最多 3 次
    local attempt out
    for attempt in 1 2 3; do
        out=$(curl -s --max-time 15 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1")
        [ -n "$out" ] && { echo "$out"; return 0; }
        sleep 2
    done
}

make_runner() {
    local name="$1" tags="$2" conc="$3"
    docker rm -f "$name" >/dev/null 2>&1 || true
    docker run -d --name "$name" --restart unless-stopped --label dev.orbstack.group=semi-cicd \
        --network semi-gitlab_default \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$PWD/data/$name:/etc/gitlab-runner" \
        "$IMG" >/dev/null
    sed -e "s/__CONCURRENT__/$conc/" -e "s/__NAME__/$name/" -e "s/__TAGS__/$tags/" \
        configs/config.toml.template > "data/$name.toml.pending"
    # token 由 bootstrap_runners.py 输出注入（TOKEN:name:token 行）
    local token
    token=$(grep "^TOKEN:$name:" /tmp/runner_tokens | cut -d: -f3)
    sed -i '' "s/__TOKEN__/$token/" "data/$name.toml.pending"
    mv "data/$name.toml.pending" "data/$name/config.toml"
    sleep 4
    docker exec "$name" gitlab-runner verify 2>&1 | grep -q "is valid" &&
        pass "$name 注册有效（tags=[$tags] concurrent=${conc}）" ||
        { fail "$name 验证失败"; docker logs "$name" 2>&1 | tail -3; exit 1; }
}

do_up() {
    step runner "签发 glrt 令牌并落两个 runner（eda concurrent=2 / fpga concurrent=1）"
    mkdir -p data/runner-eda data/runner-fpga
    docker pull -q "$IMG" >/dev/null 2>&1 || docker pull -q docker.1ms.run/gitlab/gitlab-runner:latest >/dev/null
    python3 scripts/bootstrap_runners.py "$URL" "$(cat "$TOKEN_FILE")" > /tmp/runner_tokens
    make_runner runner-eda eda 2
    make_runner runner-fpga fpga 1

    step lab "runner-lab 靶场项目 + 观察流水线"
    python3 scripts/make_pipeline.py "$URL" "$(cat "$TOKEN_FILE")"
}

wait_pipeline() {
    local pid pid_pipeline status
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frunner-lab" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    # 触发一次新流水线（重跑 verify 不依赖上次的执行痕迹）；OrbStack 偶发空响应，重试兜底
    pid_pipeline=""
    for _attempt in 1 2 3 4 5; do
        pid_pipeline=$(curl -s --max-time 20 -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects/$pid/pipeline?ref=main" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
        [ -n "$pid_pipeline" ] && break
        sleep 3
    done
    [ -n "$pid_pipeline" ] || { echo "[fail] 触发流水线失败（5 次均空响应）"; return 1; }
    echo "=====> [wait] 流水线 #${pid_pipeline}（4 jobs，最长 180s）"
    for _ in $(seq 1 60); do
        status=$(api "projects/$pid/pipelines/$pid_pipeline" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        [ "$status" = "success" ] && { echo "[ok] 流水线 success"; break; }
        [ "$status" = "failed" ] && { echo "[fail] 流水线 failed"; api "projects/$pid/pipelines/$pid_pipeline/jobs" | python3 -m json.tool | grep -E '"name"|"status"'; exit 1; }
        sleep 3
    done
    [ "$status" = "success" ] || { echo "[fail] 流水线超时未完成"; exit 1; }
    echo "$pid $pid_pipeline"
}

wait_runner_idle() {
    # 农场里可能压着前几轮的积压 job——不等到空闲，跨流水线交错会让排队断言失真
    local rid busy
    for _ in $(seq 1 40); do
        rid=$(api "runners/all" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r['description'] == 'runner-eda':
        print(r['id'])" 2>/dev/null || true)
        # 只认 list：404 dict（如 rid 空）len=1 会冒充 busy
        busy=$(api "runners/$rid/jobs?status=running" 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(len(d) if isinstance(d, list) else 9)" 2>/dev/null || echo 9)
        [ "$busy" = "0" ] && { echo "[  =] runner-eda 空闲，开始干净测量"; return 0; }
        sleep 3
    done
    echo "[fail] runner-eda 120s 未空闲"; return 1
}

do_verify() {
    local FAILED=0
    wait_runner_idle || { echo "[fail] 等不到空闲 runner"; exit 1; }
    local out
    out=$(wait_pipeline) || { echo "[fail] 流水线等待失败"; exit 1; }
    # wait_pipeline 的 stdout 混着进度 echo，ids 在最后一行
    local pid pid_pipeline
    pid=$(echo "$out" | tail -1 | awk '{print $1}')
    pid_pipeline=$(echo "$out" | tail -1 | awk '{print $2}')

    step verify "验收① 标签路由：job 落到带对应标签的 runner"
    # jobs API 的 runner 摘要不含 tag_list，runner 名即路由证据（配合 fpga-probe 落点）
    local trace1 trace2
    trace1=$(api "projects/$pid/jobs?scope[]=success" | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    if j['name'] == 'eda-1' and j.get('runner'):   # 历史 job 可能 runner=None
        print(j['id'], j['runner']['description'])")
    read -r job1_id runner_name <<<"$trace1"
    if [ "$runner_name" = "runner-eda" ]; then
        pass "eda-1 由 runner-eda 执行（tags=[eda] 路由生效）"
    else
        fail "eda-1 落到了 $runner_name"; FAILED=1
    fi
    trace2=$(api "projects/$pid/jobs?scope[]=success" | python3 -c "
import sys, json
jobs = json.load(sys.stdin)
for j in jobs:
    if j['name'] == 'fpga-probe' and j.get('runner'):
        print(j['runner']['description'])
        break")
    [ "$trace2" = "runner-fpga" ] && pass "fpga-probe 由 runner-fpga 执行" ||
        { fail "fpga-probe 落到了 $trace2"; FAILED=1; }

    step verify "验收② concurrent=2 排队：第 3 个 eda job 晚于首批完成才起跑"
    python3 - "$pid" "$pid_pipeline" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab("http://localhost:28200",
                   private_token=open("../02_org_guard/.root-token").read().strip(),
                   retry_transient_errors=True)   # OrbStack 偶发空响应，库内重试
from datetime import datetime
jobs = {j.name: j for j in gl.projects.get(int(sys.argv[1])).pipelines.get(int(sys.argv[2])).jobs.list(get_all=True)}
starts = sorted(
    datetime.fromisoformat(jobs[n].attributes["started_at"].replace("Z", "+00:00")).timestamp()
    for n in ("eda-1", "eda-2", "eda-3")
)
gap = starts[2] - starts[1]
print(f"         起跑排序间隔：{starts[1]-starts[0]:.1f}s / {gap:.1f}s（job 时长 6s，并发=2 → 第二间隔应 ≥4s）")
assert gap >= 4, f"第 3 个 job 没排队（间隔 {gap:.1f}s < 4s）——concurrent 没生效"
print("  [ok]   并发上限生效：第 3 个 job 排队等首批腾位")
PY
    [ $? -eq 0 ] || FAILED=1

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 5 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "runner 在线状态（API）"
    api "runners?status=online" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    print(f\"  #{r['id']} {r['description']} tags={r.get('tag_list')} status={r['status']}\")"
    step status "容器"
    docker stats --no-stream --format '  {{.Name}} {{.MemUsage}}' runner-eda runner-fpga 2>/dev/null
}

do_clean() {
    step clean "删 runner（API + 容器）与靶场项目"
    for r in $(api "runners" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    if r['description'] in ('runner-eda', 'runner-fpga'):
        print(r['id'])"); do
        api -X DELETE >/dev/null "runners/$r" 2>/dev/null || \
            curl -s -X DELETE -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/runners/$r" >/dev/null
        echo "[ok] 删 runner #$r"
    done
    docker rm -f runner-eda runner-fpga >/dev/null 2>&1 || true
    curl -s -X DELETE -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frunner-lab" >/dev/null && echo "[ok] 删 runner-lab"
    echo "[ok] 清理完成"
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
