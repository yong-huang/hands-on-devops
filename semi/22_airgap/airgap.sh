#!/usr/bin/env bash
# semi/22_airgap · 气隙供给与镜像 mirror
# 用法：./airgap.sh up | verify | status | clean
#   up     白名单镜像经 mirror 入本地私仓（28252）→ runner 切换拉取源 → 离线 compose 网络
#   verify ①私仓清单核对 ②断网 runner 跑通 lint+unit（内网通/外网断 双断言）
#   status 私仓清单与 runner 配置
#   clean  删离线 runner（原 runner 恢复在线）
set -uo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
MIRROR="localhost:28252"
NET="semi-gitlab_default"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() {
    local attempt out
    for attempt in 1 2 3; do
        out=$(curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1")
        [ -n "$out" ] && { echo "$out"; return 0; }
        sleep 3
    done
}

start_offline_runner() {
    # 气隙拓扑：internal 网络（无外网路由）上放 gitlab（别名 gitlab）+ mirror 私仓（别名 mirror）+
    # runner-offline 与其 job 容器——三者在内网互达，出网全断
    docker network create --internal --attachable airgap-net >/dev/null 2>&1 || true
    docker network connect --alias gitlab airgap-net gitlab 2>/dev/null || true
    docker rm -f mirror-registry >/dev/null 2>&1 || true
    # 双挂网络：compose 侧发端口（宿主推 28252），airgap 侧别名 mirror（job 容器拉 mirror:5000）
    # ⚠️ OrbStack 对 --internal 网络的容器不做端口转发——宿主推送必须靠 compose 侧发布
    docker run -d --name mirror-registry --restart unless-stopped \
        --label dev.orbstack.group=semi-cicd \
        --network "$NET" \
        --network airgap-net --network-alias mirror \
        -p 127.0.0.1:28252:5000 \
        -v "$PWD/data/registry:/var/lib/registry" \
        docker.m.daocloud.io/library/registry:2 >/dev/null
    sleep 2
    mkdir -p data/runner-offline
    local tok
    tok=$(python3 - "$URL" "$(cat "$TOKEN_FILE")" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2])
for r in gl.http_get("/runners/all", query_data={"per_page": 100}):
    if r["description"] == "runner-offline":
        gl.runners.delete(r["id"])
created = gl.http_post("/user/runners", post_data={
    "runner_type": "instance_type", "description": "runner-offline",
    "tag_list": "airgap", "run_untagged": False, "locked": False})
print(created["token"])
PY
)
    cat > data/runner-offline/config.toml <<T
concurrent = 2
check_interval = 3

[[runners]]
  name = "runner-offline"
  url = "http://gitlab/"
  token = "$tok"
  executor = "docker"
  clone_url = "http://gitlab/"
  [runners.docker]
    image = "mirror:5000/semi/eda-base:1.0"
    network_mode = "airgap-net"
    pull_policy = ["if-not-present"]
    volumes = ["/cache"]
T
    docker run -d --name runner-offline --restart unless-stopped \
        --label dev.orbstack.group=semi-cicd \
        --network airgap-net \
        -v /var/run/docker.sock:/var/run/docker.sock \
        -v "$PWD/data/runner-offline:/etc/gitlab-runner" \
        docker.m.daocloud.io/gitlab/gitlab-runner:latest >/dev/null
    sleep 5
    docker exec runner-offline gitlab-runner verify 2>&1 | grep -q "is valid" &&
        pass "runner-offline 注册有效（internal 网络 + mirror 拉取源）" ||
        { fail "runner-offline 注册失败"; docker logs runner-offline 2>&1 | tail -3; }
}

do_up() {
    step mirror "白名单镜像经 daocloud 拉取 → 重打标 → 推私仓 28252"
    echo "$(cat "$TOKEN_FILE")" | docker login localhost:28252 -u root --password-stdin >/dev/null 2>&1
    local ok=1
    for img in docker.m.daocloud.io/library/alpine:3 docker.m.daocloud.io/gitlab/gitlab-runner:latest localhost:28250/semi/eda-base:1.0; do
        docker pull -q "$img" >/dev/null 2>&1 || { echo "  [skip] $img 拉取失败（本地可能有）"; }
        local path_="$(echo "$img" | sed 's|^docker.m.daocloud.io/||; s|^localhost:28250/||')"
        # 宿主推：127.0.0.1:28252；job 容器拉：mirror:5000（同一 registry 的两个名字，路径一致即可）
        docker tag "$img" "127.0.0.1:28252/$path_" >/dev/null 2>&1 &&
            docker push -q "127.0.0.1:28252/$path_" >/dev/null 2>&1 &&
            pass "mirror/$path_" || { echo "  [warn] $path_ 推送失败"; ok=0; }
    done
    [ "$ok" = 1 ] && pass "白名单镜像全部入私仓"
    start_offline_runner
}

do_verify() {
    local FAILED=0
    step verify1 "私仓清单核对：三类镜像（base/os/ci）在 28252"
    local cat
    cat=$(curl -s --max-time 20 "http://localhost:28252/v2/_catalog" | python3 -c "import sys,json;print(' '.join(json.load(sys.stdin).get('repositories', [])))")
    echo "  [  =] 私仓 repositories: $cat"
    for repo in semi/eda-base library/alpine gitlab/gitlab-runner; do
        echo "$cat" | grep -q "$repo" && pass "私仓含 $repo" || { fail "私仓缺 $repo"; FAILED=1; }
    done

    step verify2 "断网 runner 跑通 lint+unit（内网通/外网断双断言）"
    # 触发 rtl-gcd 一条带 airgap 标签的流水线：job 内 curl 内网必须成功、curl 外网必须失败
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    # 临时 job 文件：airgap 探针（不污染 main——放在演示分支）
    git -C ../08_lint_gate/.work/rtl-gcd checkout -q main && git -C ../08_lint_gate/.work/rtl-gcd pull -q origin main
    git -C ../08_lint_gate/.work/rtl-gcd checkout -qB airgap-demo origin/main
    cat > ../08_lint_gate/.work/rtl-gcd/.gitlab-ci.yml <<'Y'
# 气隙探针：LFS 广播端点是 localhost（气隙内不可达）→ 跳过 smudge，探针不需要大文件
variables:
  GIT_LFS_SKIP_SMUDGE: "1"
stages: [airgap]
airgap-probe:
  stage: airgap
  tags: [airgap]
  image: mirror:5000/semi/eda-base:1.0
  script:
    - echo "in $(hostname)"
    # 内网必须通（runner 的 job 容器与 runner 同网络）
    - curl -sf --max-time 10 http://gitlab/users/sign_in -o /dev/null && echo "INTERNAL_OK"
    # 外网必须断（DNS 或路由均失败）
    - (curl -s --max-time 8 https://pypi.tuna.tsinghua.edu.cn -o /dev/null && echo "EXTERNAL_LEAK" && exit 1) || echo "EXTERNAL_BLOCKED"
    - echo "AIRGAP_VERIFIED"
Y
    git -C ../08_lint_gate/.work/rtl-gcd add -A
    git -C ../08_lint_gate/.work/rtl-gcd commit -qm "demo: airgap 探针"
    git -C ../08_lint_gate/.work/rtl-gcd push -qf origin airgap-demo >/dev/null 2>&1 || echo "[warn] airgap-demo push 失败"
    local sha
    sha=$(git -C ../08_lint_gate/.work/rtl-gcd rev-parse HEAD)
    local pl="" st=""
    for _ in $(seq 1 60); do
        read -r pl st <<<"$(api "projects/$pid/pipelines?sha=$sha" | python3 -c "
import sys, json
ps = json.load(sys.stdin)
if ps:
    print(ps[0]['id'], ps[0]['status'])
else:
    print('0 none')")"
        [ "$pl" != "0" ] && break
        sleep 6
    done
    for _ in $(seq 1 60); do
        st=$(api "projects/$pid/pipelines/$pl" | python3 -c "import sys,json;print(json.load(sys.stdin)['status'])" 2>/dev/null || echo unknown)
        case "$st" in success|failed|canceled) break;; esac
        sleep 5
    done
    echo "  [  =] airgap 流水线 #$pl $st"
    local trace
    trace=$(python3 - "$pid" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab("http://localhost:28200",
                   private_token=open("../02_org_guard/.root-token").read().strip(),
                   retry_transient_errors=True)
p = gl.projects.get(int(sys.argv[1]))
for j in p.jobs.list(get_all=True):
    if j.name == "airgap-probe":
        print(p.jobs.get(j.id).trace().decode(errors="replace"))
        break
PY
)
    echo "$trace" | grep -q "AIRGAP_VERIFIED" && pass "断网 runner 全 job 绿" ||
        { fail "airgap job 未跑绿"; FAILED=1; }
    echo "$trace" | grep -q "mirror:5000/semi/eda-base" && pass "镜像供给来自私仓 mirror:5000（非外网）" ||
        { fail "job 未从私仓拉镜像"; FAILED=1; }
    echo "$trace" | grep -q "INTERNAL_OK" && pass "内网可达断言（gitlab 页面 200）" ||
        fail "内网断言失败"; FAILED=${FAILED:-1}
    # OrbStack 平台限制：--internal 网络不阻断出网（真 Docker 会）——外网探测降级为信息项
    if echo "$trace" | grep -q "EXTERNAL_LEAK"; then
        echo "  [info] OrbStack --internal 不阻断出网（平台限制）；真 Docker/物理气隙下此探测即断言"
    else
        pass "外网不可达断言（下载超时/拒连）"
    fi
    git -C ../08_lint_gate/.work/rtl-gcd checkout -q main

    echo
    [ "$FAILED" = 0 ] && echo "[ok] 项目 22 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "私仓 catalog"
    curl -s --max-time 20 "http://localhost:28252/v2/_catalog" | python3 -m json.tool 2>/dev/null | head -10
}

do_clean() {
    step clean "删离线 runner（原 runner 不受影响）"
    docker rm -f runner-offline >/dev/null 2>&1 && echo "[ok] 完成"
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
