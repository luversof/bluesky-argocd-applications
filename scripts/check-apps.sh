#!/usr/bin/env bash
# argocd_application 차트가 PC별로 등록하는 Application 목록을 기대 목록(apps-<env>.txt)과 비교한다.
# 목록이 의도대로 바뀐 것이면 --update 로 기대 목록을 갱신하고 함께 커밋한다.
set -euo pipefail
cd "$(dirname "$0")/.."
rc=0
for env in home work; do
  actual=$(helm template root argocd_application --set env="$env" | sed -n 's/^  name: //p' | sort)
  if [ "${1:-}" = "--update" ]; then
    printf '%s\n' "$actual" > "scripts/apps-$env.txt"
  elif ! diff -u "scripts/apps-$env.txt" <(printf '%s\n' "$actual") --label "apps-$env.txt" --label "rendered $env"; then
    rc=1
  fi
done
[ "$rc" = 0 ] && echo "OK: home/work 목록이 기대와 같다"
exit "$rc"
