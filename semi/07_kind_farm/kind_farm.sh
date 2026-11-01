#!/usr/bin/env bash
# semi/07_kind_farm · kind 弹性农场（GitLab Runner K8s executor）
# 用法：./kind_farm.sh up | verify | status | clean
#   up     kind 集群 → 预载镜像 → glrt 令牌 → runner Pod（K8s executor，低资源 limits）→ runner-lab 加 k8s job
#   verify ①job 在 Pod 内执行（hostname 证据）②低资源+并发2 下观测 ≥2 次 Pod Pending
#   status 集群与 runner Pod 现状
#   clean  删 kind 集群（runner-lab 的 k8s job 定义保留）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
NODE_IMG="docker.m.daocloud.io/kindest/node:v1.31.0"
RUNNER_IMG="docker.m.daocloud.io/gitlab/gitlab-runner:latest"
CLUSTER="semi-farm"
HOST_IP="${HOST_IP:-$(ipconfig getifaddr en0 2>/dev/null || echo 127.0.0.1)}"
export KUBECONFIG="${KUBECONFIG:-$PWD/.kubeconfig}"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

sign_token() {
    python3 - "$URL" "$(cat "$TOKEN_FILE")" <<PY
import sys, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2])
for r in gl.http_get("/runners/all", query_data={"per_page": 100}):
    if r["description"] == "runner-k8s":
        gl.runners.delete(r["id"])
        print("[  =] 删旧 runner-k8s", file=sys.stderr)
created = gl.http_post("/user/runners", post_data={
    "runner_type": "instance_type", "description": "runner-k8s",
    "tag_list": "k8s", "run_untagged": False, "locked": False})
print(created["token"])
PY
}

do_up() {
    step kind "建 kind 集群（semi-farm，节点镜像走 daocloud）"
    if kind get clusters 2>/dev/null | grep -q "^${CLUSTER}$"; then
        echo "[  =] 集群已存在"
    else
        kind create cluster --name "$CLUSTER" --image "$NODE_IMG" \
            --kubeconfig "$KUBECONFIG" --wait 120s 2>&1 | tail -2
    fi
    kubectl --kubeconfig "$KUBECONFIG" get nodes 2>/dev/null | sed 's/^/  /'

    step preload "runner 镜像导入 kind（ctr 直导；alpine 由 Pod 自拉 daocloud）"
    # ⚠️ kind load 对带 attestation 的多架构镜像会报 content digest not found，
    #    OrbStack VM 僵死重启后本地层存储也可能缺损——docker save + ctr import 最稳
    if ! docker exec "$CLUSTER-control-plane" crictl images 2>/dev/null | grep -q "gitlab/gitlab-runner"; then
        docker save "$RUNNER_IMG" | docker exec -i "$CLUSTER-control-plane" \
            ctr --namespace=k8s.io images import - 2>&1 | tail -1
    fi
    pass "节点镜像就绪"

    step runner "runner-k8s（K8s executor，concurrent=2，cpu/mem 低限额）"
    local token
    token=$(sign_token | tail -1)
    sed -e "s/__HOST_IP__/$HOST_IP/g" -e "s/__TOKEN__/$token/g" \
        configs/runner-k8s.toml > /tmp/runner_k8s_rendered.toml
    python3 - /tmp/runner_k8s_rendered.toml configs/runner-deploy.yaml <<'PY'
import sys
toml = open(sys.argv[1]).read().rstrip()
indented = "\n".join("    " + line.strip() for line in toml.splitlines() if line.strip())
yaml = open(sys.argv[2]).read().replace("__RUNNER_TOML__", indented)
open("/tmp/runner_deploy_rendered.yaml", "w").write(yaml)
PY
    kubectl --kubeconfig "$KUBECONFIG" apply -f /tmp/runner_deploy_rendered.yaml
    kubectl --kubeconfig "$KUBECONFIG" -n gitlab rollout status deployment/runner-k8s --timeout=120s
    pass "runner Pod 就绪"
    kubectl --kubeconfig "$KUBECONFIG" -n gitlab logs deploy/runner-k8s 2>&1 | grep -q "Configuration loaded" &&
        pass "runner 配置加载（连 GitLab：http://${HOST_IP}:28200）"

    step ci "runner-lab 增加 4 个 k8s job（幂等）"
    python3 - "$URL" "$(cat "$TOKEN_FILE")" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2])
p = gl.projects.get("semi/ip/design/runner-lab")
raw = p.files.get(file_path=".gitlab-ci.yml", ref="main").decode()
cur = raw.decode() if isinstance(raw, bytes) else raw
if "k8s-1:" in cur:
    print("[  =] k8s job 已存在，跳过")
else:
    block = """
# ── 07 加装：K8s 农场 job（低资源限额，观察 Pending 排队）──
k8s-1:
  tags: [k8s]
  image: docker.m.daocloud.io/library/alpine:3
  script: sleep 8 && echo "k8s job in pod $(hostname)"
k8s-2:
  tags: [k8s]
  image: docker.m.daocloud.io/library/alpine:3
  script: sleep 8 && echo "k8s job in pod $(hostname)"
k8s-3:
  tags: [k8s]
  image: docker.m.daocloud.io/library/alpine:3
  script: sleep 8 && echo "k8s job in pod $(hostname)"
k8s-4:
  tags: [k8s]
  image: docker.m.daocloud.io/library/alpine:3
  script: sleep 8 && echo "k8s job in pod $(hostname)"
"""
    p.commits.create({"branch": "main", "commit_message": "ci: k8s 农场 job",
                      "actions": [{"action": "update" if cur else "create",
                                   "file_path": ".gitlab-ci.yml", "content": cur + block}]})
    print("[ok] 4 个 k8s job 已提交")
PY
}

do_verify() {
    local FAILED=0
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frunner-lab" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/pipeline?ref=main" >/dev/null

    step observe "后台轮询 Pending Pod（并发 2 + 低资源 → 4 job 排队，120s 观测窗）"
    local pending_seen=0
    (
        for _ in $(seq 1 120); do
            local n
            n=$(kubectl --kubeconfig "$KUBECONFIG" -n gitlab get pods \
                --field-selector=status.phase=Pending -o name 2>/dev/null | wc -l | tr -d ' ')
            [ "${n:-0}" -ge 1 ] && pending_seen=$((pending_seen + n))
            sleep 1
        done
        echo "$pending_seen" > /tmp/k8s_pending_seen
    ) &
    local poll_pid=$!

    step verify "验收① k8s job 在 Pod 内执行"
    local podname=""
    for _ in $(seq 1 60); do
        podname=$(python3 - "$pid" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab("http://localhost:28200",
                   private_token=open("../02_org_guard/.root-token").read().strip(),
                   retry_transient_errors=True)
p = gl.projects.get(int(sys.argv[1]))
for j in p.jobs.list(get_all=True):
    if j.name == "k8s-1" and j.status == "success":
        tr = p.jobs.get(j.id).trace().decode(errors="replace")
        # job Pod 名形如 runner-<tokenhash>-project-N-concurrent-X（≠ runner Pod 的 runner-k8s-*）
        if "in pod runner-" in tr and "concurrent" in tr:
            print("runner-" + tr.split("in pod runner-")[1].split()[0])
            sys.exit(0)
sys.exit(1)
PY
) || true
        [ -n "$podname" ] && break
        sleep 5
    done
    if [ -n "$podname" ]; then
        pass "k8s-1 在 Pod ${podname} 内执行（hostname 证据）"
    else
        fail "未见 Pod hostname 证据"; FAILED=1
    fi

    wait $poll_pid || true
    pending_seen=$(cat /tmp/k8s_pending_seen 2>/dev/null || echo 0)
    step verify "验收② Pending 观测累计 ≥2"
    if [ "$pending_seen" -ge 2 ]; then
        pass "观测到 ${pending_seen} 次 Pod Pending（并发 2 撞上 4 个 job）"
    else
        fail "仅观测到 ${pending_seen} 次 Pending（调度太快或并发没生效）"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 7 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "kind 集群"
    kubectl --kubeconfig "$KUBECONFIG" get nodes 2>/dev/null | sed 's/^/  /'
    step status "gitlab 命名空间"
    kubectl --kubeconfig "$KUBECONFIG" -n gitlab get pods 2>/dev/null | sed 's/^/  /'
}

do_clean() {
    step clean "删 kind 集群"
    kind delete cluster --name "$CLUSTER" 2>&1 | tail -1
    echo "[ok] 完成"
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
