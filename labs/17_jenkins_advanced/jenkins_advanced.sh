#!/usr/bin/env bash
# =============================================================================
# 17 · Jenkins 深水区 — 主演示脚本
#
# ./jenkins_advanced.sh apply     起 Jenkins → 并行 stage 计时 → 凭据打码取证 → 共享库复用
# ./jenkins_advanced.sh leak      反面教材：明文密码硬编码 → 日志泄漏演示
# ./jenkins_advanced.sh clean     销毁
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

C="lab17-jenkins"
J="http://localhost:3351"
AUTH="admin:admin123"
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

api() {
    local method="$1" path="$2"; shift 2
    local token
    token=$(docker exec "$C" cat /var/jenkins_home/lab-token.txt 2>/dev/null || echo "")
    curl -s -u "admin:${token}" -X "$method" "$J$path" "$@"
}

# 共享库必须是 git 仓（jenkins 经 file:// 拉取）
ensure_lib_repo() {
    if [ ! -d shared-lib/.git ]; then
        git init -q shared-lib && git -C shared-lib add -A \
            && git -C shared-lib -c user.email=lab@local -c user.name=lab commit -qm init \
            && git -C shared-lib branch -M master
        note "[ok] shared-lib 已初始化为 git 仓"
    fi
}

build_and_wait() {
    local job="$1" expect="$2" n next code building result
    next=$(api GET "/job/$job/api/json" | jq -r .nextBuildNumber)
    api POST "/job/$job/build" -o /dev/null
    for n in $(seq 1 60); do
        sleep 2
        code=$(api GET "/job/$job/$next/api/json" -o /dev/null -w '%{http_code}')
        [ "$code" = "200" ] || continue
        building=$(api GET "/job/$job/$next/api/json" | jq -r .building)
        [ "$building" = "false" ] || continue
        result=$(api GET "/job/$job/$next/api/json" | jq -r .result)
        note "构建 #$next 结果: $result"
        [ "$result" = "$expect" ] && return 0 || return 1
    done
    echo "    [!] 构建超时" >&2; return 1
}

do_apply() {
    step "apply" "起 Jenkins 深水区（并行 + 凭据 + 共享库）"
    ensure_lib_repo
    docker build -q -t lab17-jenkins:provisioned . >/dev/null
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker volume rm -f lab17-home >/dev/null 2>&1 || true
    docker create --name "$C" -p 3351:8080 \
        -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false -Dhudson.plugins.git.GitSCM.ALLOW_LOCAL_CHECKOUT=true" \
        -v "$(pwd)/init.groovy.d:/var/jenkins_home/init.groovy.d:ro" \
        -v "$(pwd)/shared-lib:/var/jenkins_home/shared-lib" \
        -v lab17-home:/var/jenkins_home \
        lab17-jenkins:provisioned
    # 凭据以配置文件形式在首次启动前注入（Jenkins 启动即解析）
    docker cp credentials.xml "$C":/var/jenkins_home/credentials.xml >/dev/null
    docker start "$C" >/dev/null
    local i=0
    until curl -sf -u "$AUTH" "$J/whoAmI/api/json" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 120 ] && { echo "    [!] Jenkins 未就绪" >&2; exit 1; }
        sleep 2
    done
    i=0
    until curl -sf -u "$AUTH" "$J/job/deep-release/api/json" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 45 ] && { echo "    [!] 任务未创建" >&2; exit 1; }
        sleep 2
    done
    note "[ok] 就绪"

    step "credentials" "credentials 插件 HTTP API 创建 registry 凭据"
    local token
    token=$(docker exec "$C" cat /var/jenkins_home/lab-token.txt)
    curl -s -u "admin:${token}" -X POST "$J/credentials/store/system/domain/_/createCredentials" \
        --data-urlencode 'json={"credentials": {"scope": "GLOBAL", "id": "registry-pass", "secret": "supersecret123", "$class": "org.jenkinsci.plugins.plaincredentials.impl.StringCredentialsImpl"}}' \
        -o /dev/null -w '        createCredentials → %{http_code}\n'
    note "[ok] 凭据就绪"

    step "apply" "构建：并行 stage 计时 + 凭据打码 + 共享库"
    build_and_wait deep-release SUCCESS || { echo "[x] 预期 SUCCESS" >&2; exit 1; }
    local log dur
    log=$(api GET "/job/deep-release/1/consoleText")
    dur=$(api GET "/job/deep-release/1/wfapi/describe" | jq -r '.stages[] | select(.name=="parallel") | .durationMillis' 2>/dev/null || echo "?")
    note "parallel 阶段耗时: ${dur}ms（两个 sleep 4 串行应为 8s+）"
    echo "$log" | grep -E "hello from shared library" | head -1 | LC_ALL=C sed 's/^/        /'
    if echo "$log" | grep -q "supersecret123"; then
        note "[x] 凭据泄漏进日志！" >&2; exit 1
    else
        note "[ok] 日志中无明文凭据（withCredentials 打码生效）"
    fi
}

do_leak() {
    step "leak" "反面教材：硬编码明文 → 日志泄漏演示"
    local rc=0
    build_and_wait deep-leak-demo SUCCESS || rc=$?
    api GET "/job/deep-leak-demo/1/consoleText" | grep -o "password is supersecret123" | head -1 | LC_ALL=C sed 's/^/        [x] 泄漏证据: /' || true
    note "[结论] 字符串插值不打包码——凭据只能走 credentials + withCredentials"
}

do_clean() {
    step "clean" "销毁"
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker volume rm -f lab17-home >/dev/null 2>&1 || true
    rm -rf tmp
    ! docker ps -a --format '{{.Names}}' | grep -q "^$C$" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply) do_apply ;;
        leak)  do_leak ;;
        clean) do_clean ;;
        all)   do_apply; do_leak; do_clean ;;
        *) echo "可用: apply | leak | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
