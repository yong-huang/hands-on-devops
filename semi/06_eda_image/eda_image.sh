#!/usr/bin/env bash
# semi/06_eda_image · EDA 标准执行镜像（工具链不可变交付）
# 用法：./eda_image.sh up | verify | status | clean
#   up     平台启用 Registry(28250) → 建 semi/eda-base 项目 → 构建+推送 eda-base:1.0 → runner-lab 加引用冒烟流水线
#   verify ①冒烟 job 用 Registry 镜像打印四版本 ②删本地镜像后 job 仍能从 Registry 拉起
#   status 镜像与 Registry 仓库现状
#   clean  删镜像项目与本地镜像（Registry 服务与数据保留——平台组件）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE="../02_org_guard/.root-token"
REG="localhost:28250"
IMAGE="$REG/semi/eda-base:1.0"
PLATFORM_RB="../01_gitlab_up/configs/gitlab.rb"
COMPOSE="../01_gitlab_up/configs/docker-compose.yml"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

ensure_registry() {
    step registry "平台配置演进：启用 Container Registry（28250，幂等）"
    if ! grep -q "registry_external_url" "$PLATFORM_RB"; then
        cat >> "$PLATFORM_RB" <<'RB'

## ── Container Registry（06_eda_image 加装）────────────────────────────
## 宿主 28250 → 容器 5050；镜像版本即 CI 环境契约（eda-base:1.0）
registry_external_url 'http://localhost:28250'
registry['enable'] = true
registry_nginx['listen_port'] = 5050
registry_nginx['listen_https'] = false
RB
        echo "[ok] gitlab.rb 已追加 registry 段"
    else
        echo "[  =] gitlab.rb 已含 registry 段"
    fi
    if ! grep -q "28250" "$COMPOSE"; then
        python3 - "$COMPOSE" <<'PY'
import sys
f = sys.argv[1]
s = open(f).read()
s = s.replace("      - '28222:22'                    # git+ssh",
              "      - '28222:22'                    # git+ssh\n      - '28250:5050'                  # Container Registry（06 加装）")
open(f, "w").write(s)
print("[ok] compose 已加 28250:5050 端口映射")
PY
        echo "[  =] 重建容器以加载新端口（数据卷保留，2-4 分钟）"
        docker compose -f ../01_gitlab_up/configs/docker-compose.yml up -d 2>&1 | tail -1
        ./../01_gitlab_up/scripts/healthcheck.sh
    fi
    docker exec gitlab gitlab-ctl reconfigure > /tmp/registry_reconfigure.log 2>&1
    curl -s -o /dev/null -w "  [ok] Registry /v2/ 探活: HTTP %{http_code}\n" "$REG/v2/"
}

ensure_image_project() {
    local have
    have=$(api "projects/semi%2Feda-base" | python3 -c "import sys,json;print(json.load(sys.stdin).get('id',''))" 2>/dev/null || true)
    if [ -n "$have" ]; then
        echo "[  =] 项目 semi/eda-base 已存在"
    else
        curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects" -d "path=eda-base" -d "name=EDA 基础镜像" \
            -d "namespace_id=$(api "groups/semi" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")" \
            | python3 -c "import sys,json;print('[ok] 建项目 semi/eda-base id=%s' % json.load(sys.stdin)['id'])"
    fi
    # 跨项目拉私有镜像要过 CI_JOB_TOKEN allowlist（eda-base ← runner-lab）；
    # allowlist API 不可用则降级 public（基础镜像分发型项目，public 语义也合理）
    local eda_id lab_id code
    eda_id=$(api "projects/semi%2Feda-base" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    lab_id=$(api "projects/semi%2Fip%2Fdesign%2Frunner-lab" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    code=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$eda_id/job_token_scope/allowlist" \
        -d "target_project_id=$lab_id")
    if [ "$code" = "201" ]; then
        pass "CI_JOB_TOKEN allowlist：runner-lab 已入 eda-base 白名单"
    else
        echo "  [  =] allowlist API 返回 $code，降级 public 可见性"
        curl -s -X PUT -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            "$URL/api/v4/projects/$eda_id" -d "visibility=public" >/dev/null &&
            pass "eda-base 设为 public（Registry 匿名拉取）"
    fi
}

build_and_push() {
    step build "构建 eda-base:1.0（apt+pip 国内源，约 3-6 分钟）"
    local tmp; tmp=$(mktemp -d)
    cp configs/Dockerfile configs/smoke-test.sh "$tmp/"
    # --provenance=false：buildx 默认附加 attestation 清单，GitLab Registry 会报 blob unknown
    docker build --provenance=false -t "$IMAGE" "$tmp" 2>&1 | tail -2
    rm -rf "$tmp"
    step push "登录 Registry 并推送"
    echo "$(cat "$TOKEN_FILE")" | docker login "$REG" -u root --password-stdin >/dev/null 2>&1 &&
        pass "docker login localhost:28250（root PAT）" ||
        { fail "registry 登录失败"; exit 1; }
    docker push -q "$IMAGE" && pass "已推送 $IMAGE" || { fail "push 失败"; exit 1; }
}

add_ci_ref() {
    step ci "runner-lab 增加镜像引用冒烟 job（幂等）"
    python3 - "$URL" "$(cat "$TOKEN_FILE")" <<'PY'
import sys, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2])
p = gl.projects.get("semi/ip/design/runner-lab")
try:
    # ProjectFile.decode() 返回 base64 解码后的 bytes，还要再 .decode("utf-8") 才是 str
    cur = p.files.get(file_path=".gitlab-ci.yml", ref="main").decode()
    if isinstance(cur, bytes):
        cur = cur.decode("utf-8")
except gitlab.exceptions.GitlabGetError:
    cur = ""
block = """
# ── 06 加装：eda-base 镜像冒烟（工具链版本即环境契约）──
eda-smoke:
  tags: [eda]
  image: localhost:28250/semi/eda-base:1.0
  script: smoke-test.sh
"""
if "eda-base:1.0" in cur:
    print("[  =] 冒烟 job 已存在，跳过")
else:
    p.commits.create({"branch": "main", "commit_message": "ci: eda-base 镜像冒烟 job",
                      "actions": [{"action": "update" if cur else "create",
                                   "file_path": ".gitlab-ci.yml", "content": cur + block}]})
    print("[ok] eda-smoke job 已提交")
PY
}

do_up() {
    ensure_registry
    ensure_image_project
    build_and_push
    add_ci_ref
}

do_verify() {
    local FAILED=0
    # 触发新流水线并等待 eda-smoke
    local pid
    pid=$(api "projects/semi%2Fip%2Fdesign%2Frunner-lab" | python3 -c "import sys,json;print(json.load(sys.stdin)['id'])")
    local last_pipe
    last_pipe=$(api "projects/$pid/pipelines?per_page=1" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
    curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/pipeline?ref=main" >/dev/null
    echo "=====> [wait] 等待 eda-smoke（新流水线 > #${last_pipe}，最长 300s）"
    local out
    out=$(python3 - "$URL" "$(cat "$TOKEN_FILE")" "$last_pipe" <<'PY'
import sys, time, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2], retry_transient_errors=True)
p = gl.projects.get("semi/ip/design/runner-lab")
for _ in range(60):
    for st in ("success", "failed"):
        hit = [j for j in p.jobs.list(get_all=True, scope=st, pipeline_id=None)
               if False]  # 占位防误用
    jobs = [j for j in p.jobs.list(get_all=True) if j.name == "eda-smoke"]
    fresh = [j for j in jobs if j.pipeline["id"] > int(sys.argv[3])]
    done = [j for j in fresh if j.status in ("success", "failed")]
    if done:
        j = p.jobs.get(done[0].id)
        print(j.id, j.status)
        print(j.trace().decode(errors="replace"))
        sys.exit(0)
    time.sleep(5)
sys.exit(1)
PY
) || { fail "300s 内 eda-smoke 没跑完"; exit 1; }
    local jid jstatus trace
    jid=$(echo "$out" | head -1 | awk '{print $1}')
    jstatus=$(echo "$out" | head -1 | awk '{print $2}')
    trace="$out"
    step verify "验收① 冒烟 job 用 Registry 镜像打印四版本"
    if [ "$jstatus" = "success" ] &&
       echo "$trace" | grep -q "verilator:" && echo "$trace" | grep -q "cocotb: 2.1.0" &&
       echo "$trace" | grep -q "SMOKE_OK"; then
        pass "eda-smoke #$jid success（verilator/yosys/iverilog/cocotb 版本齐全）"
        echo "$trace" | grep -E "(verilator|yosys|iverilog|cocotb):" | sed 's/^[[:space:]]*/         /'
    else
        fail "eda-smoke 未成功或输出不全（job #$jid status=${jstatus}）"
        echo "$trace" | tail -5 | sed 's/^/         /'
        FAILED=1
    fi

    step verify "验收② 删本地镜像后，job 仍能从 Registry 拉起"
    docker rmi -f "$IMAGE" >/dev/null 2>&1 && echo "  [  =] 本地镜像已删"
    if docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "semi/eda-base:1.0"; then
        fail "本地镜像删除失败"; FAILED=1
    fi
    # 重取基线：① 自己也触发过流水线，沿用 last_pipe 会把 ① 的 job 当 ② 的证据
    last_pipe=$(api "projects/$pid/pipelines?per_page=1" | python3 -c "import sys,json;print(json.load(sys.stdin)[0]['id'])")
    curl -s -X POST -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/$pid/pipeline?ref=main" >/dev/null
    out=$(python3 - "$URL" "$(cat "$TOKEN_FILE")" "$last_pipe" <<'PY'
import sys, time, gitlab
gl = gitlab.Gitlab(sys.argv[1], private_token=sys.argv[2], retry_transient_errors=True)
p = gl.projects.get("semi/ip/design/runner-lab")
for _ in range(60):
    jobs = [j for j in p.jobs.list(get_all=True) if j.name == "eda-smoke"]
    fresh = [j for j in jobs if j.pipeline["id"] > int(sys.argv[3])]
    done = [j for j in fresh if j.status in ("success", "failed")]
    if done:
        j = p.jobs.get(done[0].id)
        print(j.id, j.status)
        sys.exit(0)
    time.sleep(5)
sys.exit(1)
PY
) || { fail "第二轮 eda-smoke 未完成"; exit 1; }
    jstatus=$(echo "$out" | head -1 | awk '{print $2}')
    if [ "$jstatus" = "success" ] && docker image ls --format '{{.Repository}}:{{.Tag}}' | grep -q "semi/eda-base:1.0"; then
        pass "job 从 Registry 拉起成功且本地镜像已回填（docker images 可见）"
    else
        fail "第二轮 status=${jstatus}（镜像拉取或回填失败）"; FAILED=1
    fi

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 6 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "Registry 仓库清单（semi/eda-base）"
    curl -s "http://localhost:28250/v2/_catalog" | python3 -m json.tool 2>/dev/null | head -8
    docker exec gitlab du -sh /var/opt/gitlab/gitlab-rails/shared/registry 2>/dev/null | sed 's/^/  registry 存储: /'
    step status "本地镜像"
    docker image ls --format '  {{.Repository}}:{{.Tag}} {{.Size}}' | grep eda-base || echo "  (无)"
}

do_clean() {
    step clean "删镜像项目与本地镜像（Registry 服务保留）"
    curl -s -X DELETE -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Feda-base" >/dev/null && echo "[ok] 项目已删"
    docker rmi -f "$IMAGE" >/dev/null 2>&1 && echo "[ok] 本地镜像已删"
    docker logout "$REG" >/dev/null 2>&1 || true
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
