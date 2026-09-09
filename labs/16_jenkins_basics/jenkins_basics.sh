#!/usr/bin/env bash
# =============================================================================
# 16 · Jenkins 基础 — 主演示脚本
#
# 配置即代码：init.groovy.d 种子脚本在启动时创建流水线任务；
# 触发走 HTTP API；断言构建结果与 stage 状态（Web UI 之外的等价操作）。
#
# ./jenkins_basics.sh apply      起 Jenkins → 等任务就绪 → 触发 release-lite → 断言 SUCCESS
# ./jenkins_basics.sh fail       触发 release-lite-fail → 断言 FAILURE（stage 标红的日志证据）
# ./jenkins_basics.sh clean      销毁容器与数据卷
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

. "../../scripts/docker-env.sh"

C="lab16-jenkins"
J="http://localhost:3350"
AUTH="admin:admin123"

api() {  # api <method> <path> [curl-args...]：认证 + 会话级 CSRF crumb
    # 坑：Jenkins 的 crumb 绑定 Web 会话——GET crumb 与 POST 必须共用同一 cookie jar
    local method="$1" path="$2"; shift 2
    local crumb
    crumb=$(curl -s -c tmp/cookies -u "$AUTH" "$J/crumbIssuer/api/json" | jq -r '.crumbRequestField + ":" + .crumb')
    curl -s -b tmp/cookies -u "$AUTH" -H "$crumb" -X "$method" "$J$path" "$@"
}

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

wait_jenkins() {
    note "等待 Jenkins 就绪（首次启动含插件下载与解压，约 2-5 分钟）"
    local i=0
    until curl -sf "$J/login" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 150 ] && { echo "    [!] Jenkins 300s 未就绪" >&2; exit 1; }
        sleep 2
    done
    i=0
    until curl -sf "$J/job/release-lite/api/json" >/dev/null 2>&1; do
        i=$((i+1)); [ $i -gt 45 ] && { echo "    [!] 任务未创建" >&2; exit 1; }
        sleep 2
    done
    note "[ok] Jenkins 与流水线任务就绪"
}

start_jenkins() {
    docker build -q -t lab16-jenkins:provisioned . >/dev/null
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker volume rm -f lab16-jenkins-home >/dev/null 2>&1 || true
    docker run -d --name "$C" -p 3350:8080 \
        -e JAVA_OPTS="-Djenkins.install.runSetupWizard=false" \
        -v "$(pwd)/plugins.txt:/usr/share/jenkins/ref/plugins/plugins.txt:ro" \
        -v "$(pwd)/init.groovy.d:/var/jenkins_home/init.groovy.d:ro" \
        -v lab16-jenkins-home:/var/jenkins_home \
        lab16-jenkins:provisioned >/dev/null
}

build_and_wait() { # build_and_wait <job> <期望结论>
    local job="$1" expect="$2" n
    local next
    next=$(api GET "/job/$job/api/json" | jq -r .nextBuildNumber)
    api POST "/job/$job/build" -o /dev/null
    for n in $(seq 1 60); do
        sleep 2
        local code
        code=$(api GET "/job/$job/$next/api/json" -o /dev/null -w '%{http_code}')
        [ "$code" = "200" ] || continue
        local building result
        building=$(api GET "/job/$job/$next/api/json" | jq -r .building)
        [ "$building" = "false" ] || continue
        result=$(api GET "/job/$job/$next/api/json" | jq -r .result)
        note "构建 #$next 结果: $result"
        [ "$result" = "$expect" ] && return 0 || return 1
    done
    echo "    [!] 构建超时" >&2; return 1
}

do_apply() {
    step "apply" "起 Jenkins（配置即代码：种子脚本自动建任务）"
    start_jenkins
    wait_jenkins

    step "apply" "触发 release-lite → 断言 SUCCESS + 制品归档"
    build_and_wait release-lite SUCCESS || { echo "[x] 预期 SUCCESS" >&2; exit 1; }
    local art
    art=$(api GET "/job/release-lite/1/api/json" | jq -r '.artifacts[0].fileName // "none"')
    note "归档制品: $art"
    [ "$art" = "webapp.tar.gz" ] && note "[ok] 全流程绿（test → build → publish → archive）" \
        || { note "[x] 制品缺失" >&2; exit 1; }
}

do_fail() {
    step "fail" "注入失败的 stage → 断言 FAILURE + 日志可读"
    local rc=0
    build_and_wait release-lite-fail FAILURE || rc=$?
    if [ "$rc" != "0" ]; then note "[!] 未得到 FAILURE" >&2; exit 1; fi
    note "失败 stage 日志（标红的证据）："
    curl -s "$J/job/release-lite-fail/1/consoleText" | grep -E "injecting failure|script returned exit code 1" | sed 's/^/        /'
    note "[ok] 失败 stage 红灯 + 日志可追溯"
}

do_clean() {
    step "clean" "销毁 Jenkins 与数据卷"
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker volume rm -f lab16-jenkins-home >/dev/null 2>&1 || true
    ! docker ps -a --format '{{.Names}}' | grep -q "^$C$" && note "[ok] 零残留" || { note "[!] 残留" >&2; exit 1; }
}

main() {
    local target="${1:-all}"
    case "${target}" in
        apply) do_apply ;;
        fail)  do_fail ;;
        clean) do_clean ;;
        all)   do_apply; do_fail; do_clean ;;
        *) echo "可用: apply | fail | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
