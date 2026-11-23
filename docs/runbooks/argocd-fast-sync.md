# ArgoCD 빠른 반영 (PC마다 설정)

webhook은 이 PC로 들어올 수 없다. 그래서 ArgoCD는 git을 주기적으로 조회해야 변경을 알아챈다.
아래 두 설정으로 기다리는 시간을 줄인다.

- CI 배포: Jenkins가 buildNumber를 push한 직후 해당 앱을 refresh한다. job이 끝나고 수 초 안에 반영된다.
- 손으로 한 push: 조회 주기를 60초(+jitter 10초)로 줄인다.

git에 있는 것은 Jenkins의 ServiceAccount와 RBAC(`opensource/jenkins/templates/argocd-refresh-rbac.yaml`), 그리고 `scripts/argocd-refresh.sh`다.
아래 두 가지는 git 밖이라 PC마다 직접 한다. home은 2026-11-24에 적용했다.

## 1. Jenkins "update argocd manifest" job

대상 job은 `bluesky-project » bluesky-project ci develop update argocd manifest`와 `bluesky-cloud » bluesky-cloud ci develop update argocd manifest`다.

1. Build Environment에서 "Use secret text(s) or file(s)"를 켜고 "Git Username and Password"를 추가한다. Credentials는 `githubcredential`이다.
2. Execute shell 끝, `git commit ...` 다음 줄에 아래를 추가한다.
   ```sh
   # push here (not Git Publisher) so the ArgoCD refresh below runs after the push
   git push origin HEAD:develop
   sh scripts/argocd-refresh.sh bluesky-api- bluesky-web-   # bluesky-cloud job 은 bluesky-cloud-
   ```
3. Post-build Actions의 Git Publisher를 지운다. Git Publisher는 shell 단계 뒤에 돌기 때문에, 그대로 두면 refresh가 push보다 먼저 실행된다.
4. 주석은 ASCII로 쓴다. config.xml을 API로 올리면 한글이 깨져 500 오류가 난다.

확인: CI를 한 번 돌리고 manifest job 콘솔에서 `refresh bluesky-...` 줄을 본다.

## 2. ArgoCD 조회 주기

```sh
kubectl -n argocd patch cm argocd-cm --type merge -p '{"data":{"timeout.reconciliation":"60s","timeout.reconciliation.jitter":"10s"}}'
kubectl -n argocd rollout restart statefulset/argocd-application-controller deploy/argocd-repo-server
```

확인: `kubectl -n argocd logs statefulset/argocd-application-controller | grep appResyncPeriod`에 `appResyncPeriod=1m0s ... appResyncJitter=10s`가 보인다.
