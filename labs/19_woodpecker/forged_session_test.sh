#!/usr/bin/env bash
# 自签名 JWT 会话 + CSRF：完全确定性，绕开 OAuth 舞步时序
cd /Users/hyhit/Desktop/workspace/projects/hands-on-devops/labs/19_woodpecker
cd /Users/hyhit/Desktop/workspace/projects/hands-on-devops/labs/19_woodpecker
SECRET="lab-jwt-secret-2026"

python3 << 'PYEOF' > /tmp/wp-jwt.env
import base64, hmac, hashlib, json, time
secret = b"lab-jwt-secret-2026"
def b64(d): return base64.urlsafe_b64encode(d).rstrip(b"=").decode()
def jd(d): return json.dumps(d, separators=(",",":")).encode()
def mkjwt(claims):
    h = b64(jd({"alg":"HS256","typ":"JWT"}))
    p = b64(jd(claims))
    sig = b64(hmac.new(secret, f"{h}.{p}".encode(), hashlib.sha256).digest())
    return f"{h}.{p}.{sig}"
now = int(time.time())
sess = mkjwt({"exp": now + 86400*30, "type": "sess", "user-id": "1", "text": "sess"})
csrf = mkjwt({"exp": now + 86400*30, "type": "csrf", "text": sess})
print(f"SESS={sess}")
print(f"CSRF={csrf}")
PYEOF
source /tmp/wp-jwt.env
cat > tmp/wp-session << EOF
#Net_loc	FLAG	Secure	Expiration	Name	Value
localhost	FALSE	/	FALSE	0	user_sess	$SESS
EOF
# 验证会话 + CSRF 组合
echo "user: $(curl -s -b tmp/wp-session -H "X-CSRF-TOKEN: $CSRF" "http://localhost:3354/api/user" | jq -r '.login // "unauth"')"
# 激活仓库（gitea id=1）
act=$(curl -s -b tmp/wp-session -H "X-CSRF-TOKEN: $CSRF" -X POST "http://localhost:3354/api/repos/remote" \
    -H 'Content-Type: application/json' -d '{"forge_remote_id": 1}')
echo "activate: $(echo "$act" | jq -r '.id // ("FAIL " + (.message // ""))' 2>/dev/null || echo "$act" | head -c 60)"
