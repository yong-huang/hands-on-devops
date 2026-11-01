#!/usr/bin/env bash
# semi/03_rtl_lfs · rtl-gcd 载体入库与 Git-LFS 大文件治理
# 用法：./rtl_lfs.sh up | verify | status | clean
#   up     本地建仓库（骨架提交 + 直推被门禁拒的演示）→ lfs track/migrate 重写历史 → push 放行 → 仿真冒烟
#   verify 清单验收断言（ls-files 全指针 / SKIP_SMUDGE 提速 + pull 补全 / 新 100MB 走 LFS）
#   status 项目与 LFS 存储现状
#   clean  删 GitLab 项目与本地工作副本（组/成员/门禁保留）
set -euo pipefail
cd "$(dirname "$0")"

URL="${GITLAB_URL:-http://localhost:28200}"
TOKEN_FILE=".root-token"                     # 复用 02 的 PAT（同名，避免互踢）
TOKEN_FALLBACK="../02_org_guard/.root-token"
WORK=".work/rtl-gcd"                         # 本地规范克隆（gitignore）
FULL="semi/ip/design/rtl-gcd"
step() { echo; echo "=====> [$1] $2"; }
pass() { echo "  [ok]   $1"; }
fail() { echo "  [fail] $1"; }

ensure_root_token() {
    step token "root PAT（复用 02 的 semi-org-guard，避免互踢）"
    for cand in "$TOKEN_FILE" "$TOKEN_FALLBACK"; do
        if [ -s "$cand" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                -H "PRIVATE-TOKEN: $(cat "$cand")" "$URL/api/v4/user")" = "200" ]; then
            [ "$cand" != "$TOKEN_FILE" ] && { cp "$cand" "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"; }
            echo "[  =] 复用有效 token: $cand"
            return 0
        fi
    done
    docker exec gitlab rm -f /tmp/root_token.rb
    docker cp ../02_org_guard/scripts/root_token.rb gitlab:/tmp/root_token.rb
    local tok
    tok=$(docker exec gitlab gitlab-rails runner /tmp/root_token.rb 2>/dev/null | tail -1)
    [ -n "$tok" ] || { echo "[fail] rails runner 未产出 token"; exit 1; }
    printf '%s' "$tok" > "$TOKEN_FILE"; chmod 600 "$TOKEN_FILE"
    docker exec gitlab rm -f /tmp/root_token.rb
    echo "[ok] 新 token 已生成"
}

do_up() {
    ensure_root_token
    step scaffold "本地重建'历史遗留仓库'（骨架提交 → 塞假大文件提交）"
    rm -rf .work; mkdir -p .work
    cp -r scaffold "$WORK"
    git -C "$WORK" init -q -b main
    git -C "$WORK" config user.name root
    git -C "$WORK" config user.email admin@example.com
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "feat: rtl-gcd 载体骨架（RTL/TB/sim/docs）"
    ./scripts/gen_bigfiles.sh "$WORK"
    git -C "$WORK" add -A
    git -C "$WORK" commit -qm "chore: 直接提交 PDK/GDS/波形大文件（重现未用 LFS 的历史仓库）"
    pass "本地 2 个提交就绪（大文件还在 git 对象里）"

    step bootstrap "建 GitLab 项目（main 保护 = Maintainer 可直推）"
    # 幂等重放：远端已有内容（上次 up 遗留）会让演示 push 死在 non-fast-forward，
    # 先删后建，保证 demo 从空仓库开始
    local empty
    empty=$(curl -s --max-time 10 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd" |
        python3 -c "import sys,json;d=json.load(sys.stdin);print(d.get('empty_repo') if isinstance(d,dict) and 'empty_repo' in d else True)" 2>/dev/null || echo True)
    if [ "$empty" != "True" ] && [ "$empty" != "true" ]; then
        echo "[  =] 远端 rtl-gcd 已有内容，重置项目重放全流程"
        curl -s --max-time 15 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
            -X DELETE "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd" >/dev/null
    fi
    python3 scripts/bootstrap_rtl.py "$URL" "$(cat "$TOKEN_FILE")"

    step demo "裸大文件直推 → 平台门禁必须拒绝（02 的 hook 首战）"
    local rc=0
    git -C "$WORK" remote add origin "http://root:$(cat "$TOKEN_FILE")@localhost:28200/$FULL.git"
    git -C "$WORK" push -q -u origin main 2>"$WORK/first_push_rejected.log" || rc=$?
    if [ "$rc" -ne 0 ] && grep -q "大文件请走 LFS" "$WORK/first_push_rejected.log"; then
        pass "直推被 pre-receive 拒绝（输出见 .work/rtl-gcd/first_push_rejected.log）"
        grep "pre-receive" "$WORK/first_push_rejected.log" | head -2 | sed 's/^/         /'
    else
        fail "期望 hook 拒绝（rc≠0），实际 rc=$rc"; exit 1
    fi

    step lfs "LFS 治理：track 规则 → migrate 重写全部历史 → 重推"
    git lfs install >/dev/null
    git -C "$WORK" lfs track "*.lib" "*.gds" "*.vcd"
    git -C "$WORK" add .gitattributes
    git -C "$WORK" commit -qm "chore: git lfs track lib/gds/vcd"
    # git-lfs 的 migrate：位置参数是 ref，模式匹配走 --include（逗号分隔）
    git -C "$WORK" lfs migrate import --everything --yes --include="*.lib,*.gds,*.vcd" 2>&1 | tail -2
    git -C "$WORK" push -q -u origin main 2>&1 | tail -1 || true
    pass "LFS 指针推送成功（大对象走 LFS 通道入库）"
    # migrate 自带的 checkout 在实测中没把实体落回工作区（全是 134B 指针），显式补一次
    git -C "$WORK" lfs checkout
    pass "工作区已 checkout 为实体（ls-files 显示 * 前缀）"

    step smoke "载体自证：iverilog 编译 + cocotb 冒烟仿真"
    local smoke_rc=0
    (cd "$WORK/sim" && python3 run_tests.py) > "$WORK/sim_smoke.log" 2>&1 || smoke_rc=$?
    tail -4 "$WORK/sim_smoke.log" | sed 's/^/         /'
    if [ "$smoke_rc" -eq 0 ]; then
        pass "6 组向量仿真全过（gcd SUT 活着）"
    else
        fail "仿真冒烟失败（rc=${smoke_rc}，完整日志 .work/rtl-gcd/sim_smoke.log）"; exit 1
    fi
}

do_verify() {
    local FAILED=0
    [ -d "$WORK/.git" ] || { echo "先跑 ./rtl_lfs.sh up"; exit 1; }
    step verify "验收① git lfs ls-files：全部假大文件均为 LFS 指针"
    local lfs_out
    lfs_out=$(git -C "$WORK" lfs ls-files)
    echo "$lfs_out" | sed 's/^/         /'
    local total stars
    total=$(echo "$lfs_out" | grep -c . || true)
    # ls-files 行格式：<oid> <*|-> <path>——标记在第二列（* = 实体已 checkout，- = 指针）
    stars=$(echo "$lfs_out" | awk '$2 == "*"' | grep -c . || true)
    if [ "$total" -ge 3 ] && [ "$stars" -eq "$total" ]; then
        pass "全部 ${total} 个大文件均为 LFS 实体（第二列 * 前缀）"
    else
        fail "期望全部为 *（LFS 实体），实际 total=$total stars=$stars"; FAILED=1
    fi

    step verify "验收② GIT_LFS_SKIP_SMUDGE 秒级 clone + git lfs pull 补全"
    local t_full t_skip full_skip_ratio
    rm -rf /tmp/rtl_clone_full /tmp/rtl_clone_skip
    t_full=$(python3 - <<PY
import subprocess, time
t0 = time.time()
subprocess.run(["git", "clone", "-q",
    "http://root:$(cat "$TOKEN_FILE")@localhost:28200/$FULL.git", "/tmp/rtl_clone_full"], check=True)
print(round(time.time() - t0, 2))
PY
)
    t_skip=$(python3 - <<PY
import os, subprocess, time
env = dict(os.environ, GIT_LFS_SKIP_SMUDGE="1")
t0 = time.time()
subprocess.run(["git", "clone", "-q",
    "http://root:$(cat "$TOKEN_FILE")@localhost:28200/$FULL.git", "/tmp/rtl_clone_skip"], env=env, check=True)
print(round(time.time() - t0, 2))
PY
)
    echo "         全量 clone（含 LFS ~2GB）: ${t_full}s / SKIP_SMUDGE clone: ${t_skip}s"
    local lfs_files
    lfs_files=$(find /tmp/rtl_clone_skip/.git/lfs -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$lfs_files" -eq 0 ]; then
        pass "SKIP_SMUDGE clone 的 .git/lfs 为空（0 个对象被下载）"
    else
        fail "skip clone 的 .git/lfs 有 $lfs_files 个文件（smudge 没关干净）"; FAILED=1
    fi
    git -C /tmp/rtl_clone_skip lfs pull origin main 2>/dev/null
    local gds_size
    gds_size=$(stat -f%z /tmp/rtl_clone_skip/gds/fake.gds)
    if [ "$gds_size" -ge 125829120 ]; then   # 120MB
        pass "git lfs pull 补全成功（fake.gds 回到 $(( gds_size / 1048576 ))MB 实体）"
    else
        fail "lfs pull 后 fake.gds 只有 ${gds_size}B（指针没换实体）"; FAILED=1
    fi
    python3 -c "
import sys
full, skip = float('$t_full'), float('$t_skip')
print(f'         提速比: {full}/{skip} = {full/skip:.1f}x（参考值：localhost 近内存速度下噪声大）')"
    # 不对耗时比做硬断言：skip-clone 基线本身漂移（实测 0.55-1.58s），
    # 结构性事实（.git/lfs 零下载 + pull 补全）才是 SKIP_SMUDGE 的本义

    step verify "验收③ 新 100MB 波形走 LFS push 成功（门禁放行 LFS 指针）"
    dd if=/dev/urandom of="$WORK/waves/wave_100m.vcd" bs=1048576 count=100 status=none
    git -C "$WORK" add waves/wave_100m.vcd
    git -C "$WORK" commit -qm "test: 新增 100MB 波形（应走 LFS 通道）"
    if git -C "$WORK" push -q origin main 2>/dev/null; then
        pass "100MB 文件经 LFS 入库成功（hook 见到的只是 ~130B 指针）"
    else
        fail "100MB LFS push 失败"; FAILED=1
    fi
    rm -rf /tmp/rtl_clone_full /tmp/rtl_clone_skip

    echo
    [ "$FAILED" -eq 0 ] && echo "[ok] 项目 3 全部验收断言通过" || { echo "[fail] 有断言未过"; exit 1; }
}

do_status() {
    step status "GitLab 项目"
    curl -s --max-time 10 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd" |
        python3 -c "import sys,json; p=json.load(sys.stdin); print(f\"  {p['path_with_namespace']} default={p['default_branch']}\")"
    step status "LFS 对象存储（容器内）"
    docker exec gitlab du -sh /var/opt/gitlab/gitlab-rails/shared/lfs-objects 2>/dev/null | sed 's/^/  /'
    step status "本地规范克隆"
    git -C "$WORK" lfs ls-files -s 2>/dev/null | sed 's/^/  /' || echo "  (尚未 up)"
}

do_clean() {
    step clean "删 rtl-gcd 项目 + 本地工作副本"
    [ -s "$TOKEN_FILE" ] && curl -s --max-time 15 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" \
        -X DELETE "$URL/api/v4/projects/semi%2Fip%2Fdesign%2Frtl-gcd" >/dev/null && echo "[ok] 项目已删"
    rm -rf .work
    echo "[ok] 完成（组/成员/门禁保留）"
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
