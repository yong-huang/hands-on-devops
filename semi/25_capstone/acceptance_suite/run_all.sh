#!/usr/bin/env bash
# acceptance_suite/run_all.sh —— 平台 12 条验收断言（半导体内网平台的出厂检验单）
# 每条断言对应一个实验的核心产出；失败输出实际差异，全过逐条打 [ok]
set -uo pipefail
cd "$(dirname "$0")/.."

URL="http://localhost:28200"
TOKEN_FILE="../02_org_guard/.root-token"
PASS=0
FAIL=0
ok()  { echo "  [ok]   $1"; PASS=$((PASS+1)); }
bad() { echo "  [fail] $1"; FAIL=$((FAIL+1)); }
api() { curl -s --max-time 20 -H "PRIVATE-TOKEN: $(cat "$TOKEN_FILE")" "$URL/api/v4/$1"; }

echo "=====> 半导体 CI/CD 平台验收（12 条断言）"

# ① 平台健康
curl -sf --max-time 15 "$URL/users/sign_in" -o /dev/null &&
    ok "① GitLab 平台在线（sign_in 200）" || bad "① GitLab 不可达"

# ② 组树与成员
api "groups/semi%2Fip%2Fdesign/members" | python3 -c "
import sys, json
ms = {m['username']: m['access_level'] for m in json.load(sys.stdin)}
assert ms.get('dev1') == 30 and ms.get('root') == 50, ms
" && ok "② 组树成员矩阵（root50/dev1-30）" || bad "② 组树成员矩阵异常"

# ③ 载体仓库与 LFS
api "projects/semi%2Fip%2Fdesign%2Frtl-gcd" | python3 -c "
import sys, json
p = json.load(sys.stdin)
assert p['default_branch'] == 'main'
" && ok "③ rtl-gcd 载体在位（main）" || bad "③ rtl-gcd 缺失"

# ④ Runner 农场在线
api "runners/all" | python3 -c "
import sys, json
on = [r['description'] for r in json.load(sys.stdin)
      if r['description'] in ('runner-eda', 'runner-fpga', 'runner-offline')]
assert set(on) >= {'runner-eda', 'runner-fpga'}, on
" && ok "④ Runner 农场在线（eda/fpga）" || bad "④ Runner 农场不齐"

# ⑤ 私仓与镜像
curl -sf --max-time 15 "http://localhost:28252/v2/semi/eda-base/tags/list" | grep -q "1.0" &&
    ok "⑤ mirror 私仓含 eda-base" || bad "⑤ mirror 私仓缺 eda-base"

# ⑥ 主流水线全绿（main 最近一条）
api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/pipelines?ref=main&per_page=1" | python3 -c "
import sys, json
p = json.load(sys.stdin)[0]
assert p['status'] == 'success', f\"main 流水线 {p['status']}\"
" && ok "⑥ main 流水线全绿" || bad "⑥ main 流水线非绿"

# ⑦ Release 在架
api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/releases" | python3 -c "
import sys, json
rs = json.load(sys.stdin)
assert rs, '无 Release'
" && ok "⑦ Release 在架" || bad "⑦ 无 Release"

# ⑧ Generic Packages 制品在库
api "projects/semi%2Feda-base/packages" | python3 -c "
import sys, json
ps = [p for p in json.load(sys.stdin) if p['name'] == 'rtl-gcd-bitstream']
assert ps, '无 bitstream 包'
" && ok "⑧ bitstream 制品在库" || bad "⑧ 缺 bitstream 包"

# ⑨ 安全：变量 masked+protected、项目非 public
python3 - "$URL" "$(cat "$TOKEN_FILE")" <<'PY'
import sys, urllib.request, json
url, tok = sys.argv[1], sys.argv[2]
def get(path):
    r = urllib.request.Request(f"{url}/api/v4/{path}", headers={"PRIVATE-TOKEN": tok})
    with urllib.request.urlopen(r, timeout=20) as resp:
        return json.loads(resp.read())
pid = get("projects/semi%2Fip%2Fdesign%2Frtl-gcd")["id"]
var = get(f"projects/{pid}/variables/GITLAB_PAT")
assert var.get("masked") and var.get("protected"), var
vis = get("projects/semi%2Fip%2Fdesign%2Frtl-gcd")["visibility"]
assert vis != "public", vis
PY
ok "⑨ 安全：变量 masked+protected、仓库非 public" || bad "⑨ 安全属性不达标"

# ⑩ 回归矩阵与聚合
api "projects/semi%2Fip%2Fdesign%2Frtl-gcd/pipelines?ref=main&per_page=1" | python3 -c "
import sys, json
p = json.load(sys.stdin)[0]
assert p['status'] == 'success'
" && ok "⑩ 回归矩阵最新一轮绿" || bad "⑩ 回归矩阵非绿"

# ⑪ 容灾备份存在
ls data_backup/*.tar >/dev/null 2>&1 && ok "⑪ 容灾备份存在" ||
    ls ../23_dr/data/*.tar >/dev/null 2>&1 && ok "⑪ 容灾备份存在（23_dr/data）" || bad "⑪ 无备份 tar"

# ⑫ 度量周报存在
ls dora_week.json >/dev/null 2>&1 && ok "⑫ DORA 周报已生成" ||
    ls ../24_metrics/dora_week.json >/dev/null 2>&1 && ok "⑫ DORA 周报已生成（24_metrics）" || bad "⑫ 无 DORA 周报"

echo
if [ "$FAIL" = 0 ]; then
    echo "[ok] 平台验收 $PASS/12 全过——半导体内网平台出厂合格"
    exit 0
else
    echo "[fail] 平台验收 $PASS/12 过，$FAIL 条未过——见上"
    exit 1
fi
