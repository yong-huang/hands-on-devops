#!/usr/bin/env bash
# 自包含调试：舞步 → 会话检查 → 激活 → push → 轮询
set -euo pipefail
cd /Users/hyhit/Desktop/workspace/projects/hands-on-devops/labs/19_woodpecker
GH="http://localhost:3353"; WH="http://localhost:3354"
AUTH="devops:devops123"
jarA=/tmp/t-jA; jarB=/tmp/t-jB; rm -f "$jarA" "$jarB"

# 1) gitea 登录
csrf=$(curl -s -c "$jarA" "$GH/user/login" | grep -oE 'name="_csrf"[^>]*value="[^"]+"' | head -1 | sed 's/.*value="//;s/"//' || true)
echo "csrf=${csrf:0:10}"
curl -s -b "$jarA" -c "$jarA" -L "$GH/user/login" --data-urlencode "_csrf=$csrf" \
    --data-urlencode "user_name=devops" --data-urlencode "password=devops123" -o /dev/null

# 2) woodpecker authorize → gitea
url=$(curl -s -b "$jarA" -o /dev/null -w '%{redirect_url}' "$WH/authorize")
url=${url//lab19-gitea:3000/localhost:3353}
echo "oauth-url: ${url:0:60}"

# 3) 拉授权页；有表单就提交；没有则页面自身就是跳转
curl -s -b "$jarA" -c "$jarA" -D /tmp/t-h1 "$url" -o /tmp/t-page.html
if grep -q '/login/oauth/grant' /tmp/t-page.html; then
    ARGS=$(grep -oE '<input type="hidden" name="[^"]+" value="[^"]*"' /tmp/t-page.html \
        | sed 's/<input type="hidden" //;s/>$//' \
        | sed 's/name="\([^"]*\)" value="\([^"]*\)"/\1=\2/' | tr '\n' '&' | sed 's/&$//')
    curl -s -b "$jarA" -c "$jarA" -D /tmp/t-h2 "$GH/login/oauth/grant" --data "$ARGS&granted=true" -o /dev/null
fi
# 4) 从 h1/h2 找 code 回跳（带 code 的 Location 指向 localhost:3354）
loc=$(grep -hiE '^location' /tmp/t-h1 /tmp/t-h2 2>/dev/null | grep -oE 'code=[A-Za-z0-9_-]+' | head -1 | cut -d= -f2 || true)
echo "code=${loc:0:10}"
[ -n "$loc" ] || { echo "[x] 无 code"; exit 1; }

# 5) 用 code 完成 woodpecker 登录（会话写进 jarB）
curl -s -b "$jarA" -c "$jarB" -L "http://localhost:3354/authorize?code=$loc" -o /dev/null
echo "user: $(curl -s -b "$jarB" -c "$jarB" "$WH/api/user" | head -c 50)"

# 6) 激活仓库（gitea repo id=1）
act=$(curl -s -b "$jarB" -c "$jarB" -X POST "$WH/api/repos/remote" \
    -H 'Content-Type: application/json' -d '{"forge_remote_id": 1}')
echo "activate: $(echo "$act" | head -c 80)"
wp_id=$(echo "$act" | jq -r '.id // empty')
echo "wp_id=$wp_id"

# 7) push + 轮询
if [ ! -d repo/.git ]; then
    git -C repo init -q -b main && git -C repo add -A \
        && git -C repo -c user.email=lab@local -c user.name=lab commit -qm init
fi
git -C repo push -q "http://devops:devops123@localhost:3353/devops/demo.git" main 2>/dev/null || true
n=0
while :; do
    sleep 5; n=$((n+1)); [ $n -gt 30 ] && { echo "[!] 超时"; exit 1; }
    status=$(curl -s -b "$jarB" -c "$jarB" "$WH/api/repos/$wp_id/pipelines" | jq -r '.[0].status // empty' 2>/dev/null)
    echo "pipeline: ${status:-none}"
    [ -n "$status" ] && [ "$status" != "running" ] && [ "$status" != "pending" ] && [ "$status" != "created" ] && break
done
[ "$status" = "success" ] && echo "[ok] GREEN" || echo "[x] $status"
