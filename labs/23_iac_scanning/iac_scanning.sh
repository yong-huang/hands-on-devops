#!/usr/bin/env bash
# =============================================================================
# 23 · IaC 安全扫描三件套 — 主演示脚本
#
# 10 类编号坏配置（bad-configs/main.tf，BAD-1..10）× 三把扫描器：
#   tfsec        错配类 8 类（安全组/公网IP/S3/EBS/RDS/TLS/IMDS）
#   trivy config 同源 AVD 规则（与 tfsec 互为印证，作 CRITICAL 门禁）
#   gitleaks     凭证类 2 类（明文口令默认值 / 硬编码 AK/SK，自定义规则）
# 覆盖率 ≥9/10 断言 + good-configs 零发现 + CRITICAL 阻断门禁（双向）。
#
# ./iac_scanning.sh scan      三把扫描器全量输出（JSON 报告落 tmp/）
# ./iac_scanning.sh coverage  覆盖率断言：10 类坏配置 ≥9 类被扫出
# ./iac_scanning.sh severity  严重级归类断言（CRITICAL/HIGH）
# ./iac_scanning.sh good      good-configs 零发现断言
# ./iac_scanning.sh gate      CRITICAL 阻断门禁（坏=挡下，好=放行）
# ./iac_scanning.sh clean     清理
# ./iac_scanning.sh           # 依序全部（默认）
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

T=tmp
LOGS="$T/reports"

step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }
ok()   { echo "        ✅ $1"; }
fail() { echo "        ❌ $1" >&2; exit 1; }
must_contain() { grep -qE "$2" "$1" || fail "$3（$1 缺少 /$2/）"; ok "$3"; }

run_scanners() {
    mkdir -p "$LOGS"
    tfsec bad-configs --format json 2>/dev/null > "$LOGS/tfsec-bad.json" || true
    tfsec good-configs --format json 2>/dev/null > "$LOGS/tfsec-good.json" || true
    gitleaks detect --no-git -c .gitleaks.toml --source bad-configs \
        --report-format json --report-path "$LOGS/gitleaks.json" --exit-code 0 >/dev/null 2>&1 || true
}

tfsec_failed() {  # 从 tfsec JSON 取 failed findings（兼容 dict/list 两种形态）
    python3 - "$1" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
r = d.get('results', d) if isinstance(d, dict) else d
print(json.dumps(r.get('failed', []) if isinstance(r, dict) else r))
EOF
}

do_scan() {
    step scan "三把扫描器全量输出（报告落 $LOGS/）"
    run_scanners
    local n
    n=$(python3 -c "
import json
d = json.load(open('$LOGS/tfsec-bad.json'))
r = d.get('results', d) if isinstance(d, dict) else d
res = r.get('failed', []) if isinstance(r, dict) else r
print(len(res))")
    note "tfsec bad-configs：$n 条 failed findings"
    n=$(python3 -c "
import json
d = json.load(open('$LOGS/gitleaks.json'))
print(len(d))")
    note "gitleaks 凭证：$n 条（自定义规则，见 .gitleaks.toml）"
    n=$(trivy config --format json --quiet bad-configs 2>/dev/null | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(sum(len(r.get('Misconfigurations', [])) for r in d.get('Results', [])))")
    note "trivy config：$n 条 misconfiguration（与 tfsec 同源 AVD 规则）"
}

do_coverage() {
    step coverage "覆盖率断言：10 类编号坏配置 ≥9 类被扫出"
    run_scanners
    local covered
    covered=$(python3 - "$LOGS/tfsec-bad.json" "$LOGS/gitleaks.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
r = d.get('results', d) if isinstance(d, dict) else d
res = r.get('failed', []) if isinstance(r, dict) else r
hit = {x.get('resource', '') for x in res}
tfsec_classes = {
    "BAD-1 安全组全开":     "aws_security_group.open",
    "BAD-2 公网 IP":        "aws_instance.public_ip",
    "BAD-5 S3 公网阻断关":  "aws_s3_bucket_public_access_block.off",
    "BAD-6 EBS 未加密":     "aws_ebs_volume.unencrypted",
    "BAD-7 S3 无加密":      "aws_s3_bucket.public",
    "BAD-9 RDS 未加密":     "aws_db_instance.unencrypted",
    "BAD-10 IMDSv1":        "aws_instance.imds_v1",
    "BAD-8 过期 TLS":       "aws_lb_listener.legacy_tls",
}
n = 0
for label, res_name in tfsec_classes.items():
    hit_flag = res_name in hit
    n += hit_flag
    print(f"  {'OK ' if hit_flag else 'MISS'} {label} <- tfsec {res_name}")
leaks = json.load(open(sys.argv[2]))
rule_ids = {x['RuleID'] for x in leaks}
for label, rid in {"BAD-3 明文口令默认值": "tf-plaintext-password-default",
                   "BAD-4 硬编码 AK/SK":  "aws-access-key-id"}.items():
    hit_flag = rid in rule_ids
    n += hit_flag
    print(f"  {'OK ' if hit_flag else 'MISS'} {label} <- gitleaks {rid}")
print(f"COVERED={n}")
EOF
)
    echo "$covered" | sed 's/^/        /'
    local total
    total=$(echo "$covered" | grep -oE "COVERED=[0-9]+" | cut -d= -f2)
    [ "${total:-0}" -ge 9 ] || fail "覆盖率 ${total:-0}/10 < 9"
    ok "覆盖率 ${total}/10 ≥ 9（验收线）"
}

do_severity() {
    step severity "严重级归类（CRITICAL / HIGH）"
    run_scanners
    python3 - "$LOGS/tfsec-bad.json" <<'EOF'
import json, sys
d = json.load(open(sys.argv[1]))
r = d.get('results', d) if isinstance(d, dict) else d
res = r.get('failed', []) if isinstance(r, dict) else r
from collections import Counter
sev = Counter(x['severity'].upper() for x in res)
crit, high = sev.get('CRITICAL', 0), sev.get('HIGH', 0)
print(f"  CRITICAL={crit}  HIGH={high}  MEDIUM={sev.get('MEDIUM',0)}  LOW={sev.get('LOW',0)}")
assert crit >= 2, f"CRITICAL={crit} 应 >=2（全开安全组 + 过期 TLS）"
assert high >= 10, f"HIGH={high} 应 >=10"
print("  [PASS] 归类断言：CRITICAL>=2 且 HIGH>=10")
EOF
    ok "严重级归类通过"
}

do_good() {
    step good "good-configs 零发现断言"
    run_scanners
    local n
    n=$(python3 -c "
import json
d = json.load(open('$LOGS/tfsec-good.json'))
r = d.get('results', d) if isinstance(d, dict) else d
res = r.get('failed', []) if isinstance(r, dict) else r
print(len(res))")
    [ "$n" = "0" ] || fail "good-configs 应零发现，实为 $n 条"
    ok "good-configs 零发现（合规样本经得起同一把尺子）"
}

do_gate() {
    step gate "HIGH+ 阻断门禁（双向：坏=挡下，好=放行）"
    # 注：tfsec 与 trivy 对同一 AVD ID 的评级不一致（tfsec 的 2 条 CRITICAL
    # 在 trivy 里是 HIGH）——门禁阈值用 HIGH,CRITICAL 才能在两家都成立
    local rc=0
    trivy config --severity HIGH,CRITICAL --exit-code 1 --quiet bad-configs >/dev/null 2>&1 || rc=$?
    [ "$rc" != "0" ] || fail "HIGH+ 未阻断坏配置（rc=0）"
    ok "坏配置被 HIGH+ 阈值挡下（rc=$rc → pipeline fail）"
    rc=0
    trivy config --severity HIGH,CRITICAL --exit-code 1 --quiet good-configs >/dev/null 2>&1 || rc=$?
    [ "$rc" = "0" ] || fail "HIGH+ 阈值误杀好配置（rc=${rc}）"
    ok "好配置过闸（rc=0 → pipeline 继续）"
}

do_clean() {
    step clean "清理报告"
    rm -rf "$T"
    note "[ok] 零残留"
}

main() {
    local target="${1:-all}"
    case "${target}" in
        scan)     do_scan ;;
        coverage) do_coverage ;;
        severity) do_severity ;;
        good)     do_good ;;
        gate)     do_gate ;;
        clean)    do_clean ;;
        all)
            do_scan
            do_coverage
            do_severity
            do_good
            do_gate
            do_clean
            echo; echo "✅ 23 全部通过"
            ;;
        *) echo "可用: scan | coverage | severity | good | gate | clean | all" >&2; exit 1 ;;
    esac
}

main "$@"
