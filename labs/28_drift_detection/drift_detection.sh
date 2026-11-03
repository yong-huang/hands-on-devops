#!/usr/bin/env bash
# =============================================================================
# 28 · 配置漂移检测与治理 — 主演示脚本
#
# 期望态：TF 管 web 容器（docker provider）+ ansible 管容器内配置。
# 三类漂移注入 × 双探针+专项检测 → 分类定位 → 一键回正 → 终态断言。
#   inject-config  容器内 motd 被手改        → ansible --check 检出
#   inject-rebuild 容器被手动重建（参数走样） → TF plan -detailed-exitcode 检出
#   inject-image   registry 同 tag 被覆盖    → digest 专项探针检出（TF 不可见！）
#
# ./drift_detection.sh setup           建镜像+推 registry+TF apply 期望态+ansible 渲染
# ./drift_detection.sh inject-config   注入漂移①（容器内配置）
# ./drift_detection.sh inject-rebuild  注入漂移②（手动重建容器）
# ./drift_detection.sh inject-image    注入漂移③（registry tag 覆盖）
# ./drift_detection.sh detect          双探针+专项检测 → 分类报告（JSON 落 tmp/）
# ./drift_detection.sh restore         按检出分类一键回正
# ./drift_detection.sh assert-clean    终态断言（双探针全绿 + 服务健康）
# ./drift_detection.sh clean           销毁
# ./drift_detection.sh                 # 全治理演练（setup→注入→检测→回正→终态）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

T="tmp"
WEB_PORT=28230
REG="localhost:5500"
APP="drift28/app:1.0"
IMG="$REG/$APP"
C="drift28-web"
POLL=150

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }

stage_tfrc() {  # provider filesystem mirror（registry.terraform.io 本网络 RST）
    # 绝对路径：TF 在 tf/ 子目录解析，相对 mirror 会 lstat 失败（实测）
    local mirror="$PWD/$T/tf-mirror"
    local provider_src="$PWD/../../labs/01_tf_docker_provider/configs/.terraform/providers/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64/terraform-provider-docker_v3.9.0"
    mkdir -p "$mirror/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64"
    cp "$provider_src" \
        "$mirror/registry.terraform.io/kreuzwerker/docker/3.9.0/darwin_arm64/" 2>/dev/null
    cat > "$T/tfrc" <<EOF2
provider_installation {
  filesystem_mirror {
    path    = "$mirror"
    include = ["registry.terraform.io/*/*"]
  }
  direct {
    exclude = ["registry.terraform.io/*/*"]
  }
}
EOF2
    export TF_CLI_CONFIG_FILE="$T/tfrc"
}

tf() { ( cd tf && terraform -chdir=. "$@" ) 2>&1; }

ensure_registry() {
    curl -s -m 4 "$REG/v2/_catalog" >/dev/null 2>&1 && return 0
    docker start lab-registry >/dev/null 2>&1 || true
    sleep 3
    curl -s -m 4 "$REG/v2/_catalog" >/dev/null 2>&1 || fail "registry $REG 未就绪（先跑 labs/14 的 registry）"
}

build_and_push() {  # build_and_push <Dockerfile> → push 并记录 manifest digest 基线
    docker build -q -t "$IMG" -f "$1" images >/dev/null
    local out
    out=$(docker push "$IMG" 2>&1 | tail -1)
    local digest
    digest=$(echo "$out" | grep -oE "sha256:[a-f0-9]{64}" | tail -1)
    [ -n "$digest" ] || { docker push "$IMG" 2>&1 | tail -3; fail "push 未返回 digest"; }
    echo "$digest" > "$T/expected-digest.txt"
    note "镜像已推：${IMG}（digest 基线 ${digest:0:20}…）"
}

registry_digest() {  # registry API 当前 tag 的权威 digest（响应头，勿自行 hash：
    # push 是 OCI 格式、GET 带 docker Accept 会返回转换后的字节——自行 sha256 恒不等）
    local name="${APP%%:*}" tag="1.0"   # APP="repo/name:tag" -> name 与 tag 拆开
    curl -s -m 6 -D - -o /dev/null \
        -H "Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json" \
        "$REG/v2/$name/manifests/$tag" 2>/dev/null \
        | grep -i "^docker-content-digest:" | awk '{print $2}' | tr -d '\r' | tail -1
}

ansible_run() {  # ansible_run <check|apply> → 输出（docker 连接，免 SSH）
    local mode="$1" inv="$T/inventory.ini"
    docker inspect "$C" >/dev/null 2>&1 || fail "容器不在（${C}）"
    printf '[drift28]\ndrift28-web\n[drift28:vars]\nansible_connection=community.docker.docker\nansible_host=%s\nansible_python_interpreter=/usr/local/bin/python3\n' "$C" > "$inv"
    # </dev/null：docker 连接插件的子进程可能持有 stdin 导致命令替换挂死（实测）
    if [ "$mode" = "check" ]; then
        ansible-playbook -i "$inv" ansible/playbook.yml --check </dev/null 2>&1
    else
        ansible-playbook -i "$inv" ansible/playbook.yml </dev/null 2>&1
    fi
}

do_setup() {
    step setup "构建/推送可信镜像 + TF apply 期望态 + ansible 渲染基线"
    mkdir -p "$T"
    stage_tfrc
    ensure_registry
    docker rm -f "$C" >/dev/null 2>&1 || true
    build_and_push images/app.Dockerfile
    ( cd tf && terraform init -input=false >/dev/null 2>&1 ) || fail "terraform init 失败"
    tf apply -auto-approve >/dev/null
    note "TF apply 完成（期望态建立）"
    ansible_run apply | grep -E "changed=[0-9]" | sed 's/^/        /'
    sleep 2
    local code
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT/")
    [ "$code" = "200" ] || fail "服务 :$WEB_PORT 未就绪（${code}）"
    ok "期望态就绪：$C @ :${WEB_PORT}（registry tag → digest 基线已记录）"
}

do_inject_config() {
    step inject-config "注入漂移①：容器内 motd 被手改（绕过 ansible）"
    docker exec "$C" sh -c 'echo "TAMPERED by hand" > /etc/motd'
    ok "已注入（TF 视角无感知——容器本身没变）"
}

do_inject_rebuild() {
    step inject-rebuild "注入漂移②：容器被手动重建（端口走样 + 无 command）"
    docker rm -f "$C" >/dev/null
    docker run -d --name "$C" -p "$WEB_PORT:$WEB_PORT" python:3.12-slim \
        sh -c "python3 -m http.server $WEB_PORT" >/dev/null
    ok "已注入（容器是同名但非 TF 建的——端口映射/镜像/command 全走样）"
}

do_inject_image() {
    step inject-image "注入漂移③：registry 同 tag 被覆盖（供应链劫持）"
    docker build -q -t "$IMG" -f images/malicious.Dockerfile images >/dev/null
    docker push "$IMG" >/dev/null 2>&1
    ok "已注入（tag 未变、manifest digest 已变——TF/ansible 双盲区）"
}

do_detect() {
    step detect "双探针 + 专项检测 → 分类报告"
    mkdir -p "$T"
    stage_tfrc
    local tf_rc=0 ansible_changed=0 digest_bad=0
    set +e
    tf plan -detailed-exitcode -no-color > "$T/plan.log" 2>&1
    tf_rc=$?
    set -e
    case "$tf_rc" in
        0) note "探针 TF plan：exit 0（无基础设施漂移）" ;;
        2) note "探针 TF plan：exit 2（检出基础设施漂移）"
           grep -E "^  ~ |^  -/+ |will be (created|destroyed|replaced)" "$T/plan.log" | head -4 | sed 's/^/        /' ;;
        *) fail "TF plan 异常退出码 ${tf_rc}（看 $T/plan.log）" ;;
    esac

    local out="\nchanged=0\n"
    out=$(ansible_run check) || true
    # 防御式计数：ansible --check 有变更时 rc=2；管道无匹配也是 rc=1——set -e 下全部兜底
    ansible_changed=$(echo "$out" | { grep -oE "changed=[0-9]+" || echo "changed=0"; } | { grep -oE "[0-9]+" || echo 0; } | awk '{s+=$1} END {print s+0}') || ansible_changed=0
    if [ "$ansible_changed" -gt 0 ]; then
        note "探针 ansible --check：$ansible_changed 项漂移（容器内配置被改）"
    else
        note "探针 ansible --check：0 changed（配置无漂移）"
    fi

    local want now
    # 基线缺失/读不到都是错误（静默空值会造成假 SAME）
    [ -s "$T/expected-digest.txt" ] || fail "digest 基线缺失（$T/expected-digest.txt）"
    want=$(cat "$T/expected-digest.txt")
    now=$(registry_digest)
    [ -n "$now" ] || fail "registry digest 读取失败（registry 是否在线？）"
    if [ -n "$want" ] && [ "$want" != "$now" ]; then
        digest_bad=1
        note "专项 digest 探针：tag 被覆盖（基线 ${want:0:20}… ≠ 现网 ${now:0:20}…）"
    else
        note "专项 digest 探针：tag 与基线一致（${now:0:20}…）"
    fi

    # 分类报告
    python3 - "$tf_rc" "$ansible_changed" "$digest_bad" > "$T/drift-report.json" <<'EOF'
import json, sys
tf, ans, dig = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
report = {
    "terraform_drift": tf == 2,
    "ansible_drift": ans > 0,
    "image_hijack": dig == 1,
    "root_cause": ("基础设施层：容器被手动重建（TF 接管重建）" if tf == 2 else
                   "配置层：容器内文件被手改（ansible 重渲染）" if ans > 0 else
                   "registry 层：tag 被覆盖（重推干净镜像+重建容器+刷新基线）" if dig == 1 else
                   "无漂移"),
}
print(json.dumps(report, ensure_ascii=False, indent=1))
EOF
    cat "$T/drift-report.json" | sed 's/^/        /'
}

do_restore() {
    step restore "按检出分类一键回正"
    local tfd ansd digd
    tfd=$(python3 -c "import json; print(json.load(open('$T/drift-report.json')).get('terraform_drift'))" 2>/dev/null || echo "False")
    ansd=$(python3 -c "import json; print(json.load(open('$T/drift-report.json')).get('ansible_drift'))" 2>/dev/null || echo "False")
    digd=$(python3 -c "import json; print(json.load(open('$T/drift-report.json')).get('image_hijack'))" 2>/dev/null || echo "False")

    if [ "$tfd" = "True" ]; then
        stage_tfrc
        docker rm -f "$C" >/dev/null 2>&1 || true   # 走样的手建容器先移除，TF 重建期望态
        tf apply -auto-approve >/dev/null
        ok "基础设施漂移回正：TF apply 重建期望容器"
    fi
    if [ "$digd" = "True" ]; then
        build_and_push images/app.Dockerfile        # 干净镜像恢复 tag
        stage_tfrc
        docker rm -f "$C" >/dev/null 2>&1 || true
        tf apply -auto-approve -replace=docker_container.web >/dev/null
        ok "registry 漂移回正：干净镜像重推 + 容器重建 + digest 基线刷新"
    fi
    if [ "$ansd" = "True" ] || [ "$digd" = "True" ] || [ "$tfd" = "True" ]; then
        ansible_run apply | grep -E "changed=[0-9]" | sed 's/^/        /'
        ok "配置回正：ansible 幂等重渲染"
    fi
}

do_assert_clean() {
    step assert-clean "终态断言（双探针全绿 + 服务健康）"
    stage_tfrc
    local tf_rc=0
    set +e
    tf plan -detailed-exitcode -no-color >/dev/null 2>&1
    tf_rc=$?
    set -e
    [ "$tf_rc" = "0" ] || fail "TF plan 仍检出漂移（exit=${tf_rc}）"
    ok "TF plan exit 0（基础设施与期望态一致）"

    local changed
    changed=$(ansible_run check | { grep -oE "changed=[0-9]+" || echo "changed=0"; } | { grep -oE "[0-9]+" || echo 0; } | awk '{s+=$1} END {print s+0}') || changed=0
    [ "$changed" = "0" ] || fail "ansible --check 仍有 $changed 项漂移"
    ok "ansible --check 0 changed（配置与期望态一致）"

    local want now
    want=$(cat "$T/expected-digest.txt")
    now=$(registry_digest)
    [ "$want" = "$now" ] || fail "digest 基线与现网不一致"
    ok "digest 基线一致（registry 内容可信）"

    local code page
    code=$(curl -s -m 5 -o /dev/null -w "%{http_code}" "http://localhost:$WEB_PORT/")
    page=$(curl -s -m 5 "http://localhost:$WEB_PORT/")
    [ "$code" = "200" ] && [ "$page" = "drift28 expected page" ] \
        || fail "服务异常（$code / ${page}）"
    ok "服务健康且页面为期望内容（:${WEB_PORT}）"
}

do_clean() {
    step clean "销毁"
    stage_tfrc
    ( cd tf && terraform destroy -auto-approve >/dev/null 2>&1 ) || true
    docker rm -f "$C" >/dev/null 2>&1 || true
    docker rmi "$IMG" >/dev/null 2>&1 || true
    rm -rf "$T"
    note "[ok] 零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        setup)          do_setup ;;
        inject-config)  do_inject_config ;;
        inject-rebuild) do_inject_rebuild ;;
        inject-image)   do_inject_image ;;
        detect)         do_detect ;;
        restore)        do_restore ;;
        assert-clean)   do_assert_clean ;;
        clean)          do_clean ;;
        all)
            do_setup
            # 漂移①：配置
            do_inject_config; do_detect; do_restore; do_assert_clean
            # 漂移②：基础设施
            do_inject_rebuild; do_detect; do_restore; do_assert_clean
            # 漂移③：registry
            do_inject_image; do_detect; do_restore; do_assert_clean
            do_clean
            echo; echo "✅ 28 全部通过"
            ;;
        *) echo "可用: setup | inject-config | inject-rebuild | inject-image | detect | restore | assert-clean | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
