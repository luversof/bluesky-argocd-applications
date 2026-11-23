#!/bin/sh
# 이름이 주어진 접두어로 시작하는 ArgoCD 앱을 refresh 한다. Jenkins pod 의 ServiceAccount 로 k8s API 를 직접 부른다.
# 쓰는 곳: Jenkins "update argocd manifest" job, buildNumber push 직후 (opensource/jenkins/templates/argocd-refresh-rbac.yaml)
# 사용: sh scripts/argocd-refresh.sh bluesky-api- bluesky-web-
set -eu
[ $# -gt 0 ] || { echo "usage: $0 <app-name-prefix>..." >&2; exit 2; }
SA=/var/run/secrets/kubernetes.io/serviceaccount
API=https://kubernetes.default.svc/apis/argoproj.io/v1alpha1/namespaces/argocd/applications
k() { curl -sSf --cacert "$SA/ca.crt" -H "Authorization: Bearer $(cat "$SA/token")" "$@"; }

n=0
for app in $(k "$API" | jq -r '.items[].metadata.name'); do
  for prefix in "$@"; do
    case $app in "$prefix"*)
      k -X PATCH -H 'Content-Type: application/merge-patch+json' \
        -d '{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}' "$API/$app" >/dev/null
      echo "refresh $app"
      n=$((n + 1))
      break
    esac
  done
done
[ "$n" -gt 0 ] || { echo "no app matches: $*" >&2; exit 1; }
