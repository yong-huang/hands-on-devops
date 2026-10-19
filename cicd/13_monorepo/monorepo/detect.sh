#!/usr/bin/env bash
# =============================================================================
# affected 检测（本地 git diff 版）：detect.sh <base-ref> <head-ref>
# 输出受影响模块的 JSON 数组，如 ["a","c"]。
#
# 依赖图（谁依赖谁）：
#   apps/a → libs/common
#   apps/b → libs/common
#   apps/c → apps/a + libs/common     ← 模块间也有边：改 a 会扇出到 c
# 判定：改动模块 ∪ 所有（传递）依赖它们的模块 = 受影响集合
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")"

base="${1:?用法: detect.sh <base-ref> <head-ref>}"
head="${2:?用法: detect.sh <base-ref> <head-ref>}"

dep_of() {  # 模块 → 直接依赖的模块名（空格分隔；注释给"想加模块间边"的读者）
    case "$1" in
        a)      echo "common" ;;
        b)      echo "common" ;;
        c)      echo "common" ;;
        common) echo "" ;;
    esac
}
# 注：若加模块间边（如 c 依赖 a），把 c 的依赖写成 "a common" 即可——
# 闭包自动让"改 a"扇出到 c；本实验为让"只改 A → B/C skip"成立保持平坦。

# 文件路径 → 模块名
mod_of() {
    case "$1" in
        apps/a/*)           echo "a" ;;
        apps/b/*)           echo "b" ;;
        apps/c/*)           echo "c" ;;
        libs/common/*)      echo "common" ;;
        # 流水线自身变更保守起见触发全量
        .github/workflows/*|detect.sh) echo "a b c common" ;;
        *)                  echo "" ;;
    esac
}

affected=""
add() { case " ${affected} " in *" $1 "*) ;; *) affected="${affected} $1";; esac; }

while IFS= read -r f; do
    [ -n "$f" ] || continue
    for m in $(mod_of "$f"); do add "$m"; done
done < <(git diff --name-only "$base" "$head" 2>/dev/null || true)

# 反向闭包：循环直到不再有新模块（common 变 → a/b/c 变；a 变 → c 变）
changed="yes"
while [ "$changed" = "yes" ]; do
    changed="no"
    for m in a b c common; do
        case " ${affected} " in *" ${m} "*) continue ;; esac
        for dep in $(dep_of "$m"); do
            case " ${affected} " in *" ${dep} "*)
                add "$m"; changed="yes"; break ;;
            esac
        done
    done
done

out="["
sep=""
for m in a b c; do
    case " ${affected} " in *" ${m} "*) out="${out}${sep}\"${m}\""; sep=",";; esac
done
echo "${out}]"
