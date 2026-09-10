#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p tmp
export SOPS_AGE_KEY_FILE=tmp/key.txt
step() { echo; echo "=====> [$1] $2"; }
note() { echo "        $1"; }

step "keygen" "生成 age 密钥对"
if [ ! -f tmp/key.txt ]; then
    age-keygen -o tmp/key.txt 2>/dev/null
    note "[ok] 密钥对已生成"
fi
RECIPIENT=$(grep "public key" tmp/key.txt | awk '{print $NF}')

step "encrypt" "SOPS 加密 secrets.yaml"
cat > secrets.yaml <<'YAML'
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:
  username: admin
  password: super-secret-password-2026
YAML
sops --encrypt --age "$RECIPIENT" --in-place secrets.yaml
grep -q "super-secret" secrets.yaml && note "[x] 明文泄漏！" || note "[ok] 密文无明文"

step "decrypt" "SOPS 解密"
sops --decrypt --in-place secrets.yaml
grep -q "super-secret" secrets.yaml && note "[ok] 解密成功值一致"

step "clean" "清理"
rm -rf tmp secrets.yaml
note "[ok] 零残留"
