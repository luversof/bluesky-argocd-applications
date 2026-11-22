# 다른 PC: app-of-apps 루트 앱 등록

2026-11-14 커밋 `092d977`에서 `argocd_application/`을 Application 목록을 렌더하는 Helm 차트(app-of-apps)로 바꿨다.
PC 차이는 `env` 값 하나다: `home`은 `subchart_home/buildInfo-*`와 `values-home.yaml`, `work`는 `subchart_work/buildInfo-*`와 `values-work.yaml`을 쓴다.
home PC에는 루트 앱 `bluesky-root`가 등록되어 있고, 자식 Application 31개의 spec은 전환 전과 같았다.
이 문서는 **work PC**에서 루트 앱을 등록하는 절차다. 등록 전까지 이 PC의 Application은 예전처럼 ArgoCD UI에서 관리된 상태 그대로다.

## 0. 먼저 지킬 것

- 루트 앱이 등록되면 같은 이름의 기존 Application을 넘겨받고, git의 spec으로 덮어쓴다.
  그래서 **등록 전에 이 PC의 실제 spec과 `env=work` 렌더 결과를 비교해 차이를 0으로 만든다.** 차이가 있는 채로 등록하면 그 앱의 valueFiles나 sync 정책이 바뀌어 워크로드가 다시 배포될 수 있다.
- 차이를 없애는 방법은 둘 중 하나다. 어느 쪽이 맞는지 판단이 안 서면 사용자에게 묻는다.
  - git이 맞으면: 그 차이는 받아들인다(등록하면 git 값으로 바뀐다). 영향받는 앱을 사용자에게 알린다.
  - 실제 상태가 맞으면: `argocd_application/values.yaml`(앱 목록, `envs`, `valuesObject`)이나 차트를 고쳐 git을 실제에 맞춘다.
    **home PC 렌더 결과가 바뀌지 않게 한다.** 고친 뒤 `env=home` 렌더 결과도 커밋 전과 같은지 확인한다.
- 루트 앱의 `prune`은 `false`다. 목록에 없는 이 PC의 Application은 지워지지 않고 그대로 남는다(루트 앱이 관리하지 않을 뿐).
- 기존 Application에는 `resources-finalizer`가 없다. 넣지 않는다. Application을 지워도 워크로드가 남게 하려는 것이다.
- **오픈소스는 PC마다 설치한 것이 다르다. 이 PC에 실제로 설치된 것만 등록한다.**
  `values.yaml`의 `opensource` 항목은 `envs`에 적힌 PC에만 등록된다(`envs`가 없거나 `[]`이면 어디에도 등록하지 않는다).
  2026-11-22 현재 대부분 `envs: [home, work]`다(work PC가 2026-11-16 Reposilite·zot 전환 때 추가). 등록 전에 `env=work` 렌더 결과의 opensource 앱이 이 PC에 실제로 설치되어 있는지 확인하고, 없는 것은 `work`를 뺀다(1-1번).
  설치되지 않은 오픈소스에 `work`를 넣으면 루트 앱 등록과 함께 새로 설치되므로 넣지 않는다. 새로 설치하려는 것이면 사용자에게 먼저 묻는다.

## 1. 준비

```bash
cd <bluesky-argocd-applications 클론>
git checkout develop && git pull
kubectl -n argocd get application bluesky-root   # 이미 있으면 이 문서 작업은 끝난 것이다. 3번 확인만 한다.
```

## 1-1. 이 PC에 설치된 오픈소스 확인과 envs 반영

이 PC의 ArgoCD에 등록된 opensource 앱과, 실제로 떠 있는 워크로드를 같이 본다.

```bash
kubectl -n argocd get applications -o jsonpath='{range .items[?(@.spec.project=="opensource")]}{.metadata.name}{"\t"}{.spec.source.path}{"\t"}{.status.sync.status}/{.status.health.status}{"\n"}{end}'
kubectl -n opensource get deploy,statefulset
```

- ArgoCD에 등록되어 있고 워크로드도 있는 앱: `values.yaml`에서 그 항목의 `envs`에 `work`를 추가한다(예: `envs: [home]` → `envs: [home, work]`, `envs: []` → `envs: [work]`).
- ArgoCD에 등록되어 있지만 워크로드가 없거나 Missing인 앱: 의도한 상태인지 사용자에게 묻고, 답에 따라 넣거나 뺀다.
- `opensource/` 폴더에 차트가 있어도 이 PC의 ArgoCD에 없는 앱: 넣지 않는다.
- `values.yaml` 목록에 없는 앱이 이 PC에 있으면: 계속 git으로 관리할지 사용자에게 묻고, 관리한다면 항목을 추가하고 `envs: [work]`를 준다(`path`가 `opensource/<name>`이 아니면 `path`도 적는다).

## 2. 실제 spec과 렌더 결과 비교

```bash
mkdir -p "$TEMP/aoa"
kubectl -n argocd get applications -o json > "$TEMP/aoa/live.json"
helm template root argocd_application --set env=work > "$TEMP/aoa/work.yaml"
kubectl create --dry-run=client -o json -f "$TEMP/aoa/work.yaml" > "$TEMP/aoa/work.json"
python - "$TEMP/aoa" <<'EOF'
import json, sys, pathlib
sys.stdout.reconfigure(encoding='utf-8')
d = pathlib.Path(sys.argv[1])
live = {x['metadata']['name']: x['spec'] for x in json.loads((d/'live.json').read_text(encoding='utf-8'))['items']}
s = (d/'work.json').read_text(encoding='utf-8'); dec = json.JSONDecoder(); i = 0; ren = {}
while i < len(s):
    while i < len(s) and s[i].isspace(): i += 1
    if i >= len(s): break
    o, i = dec.raw_decode(s, i); ren[o['metadata']['name']] = o['spec']
print('live 에만 있음 (루트 앱이 관리하지 않음):', sorted(set(live) - set(ren)))
print('렌더에만 있음 (등록하면 새로 생김):', sorted(set(ren) - set(live)))
for n in sorted(set(live) & set(ren)):
    if json.dumps(live[n], sort_keys=True) != json.dumps(ren[n], sort_keys=True):
        print('DIFF', n); print('  live', json.dumps(live[n], sort_keys=True)); print('  rend', json.dumps(ren[n], sort_keys=True))
EOF
```

결과를 이렇게 처리한다.

- **DIFF**: 0번의 방법으로 없앤다. home PC 기준으로 알려진 형태는 이렇다(다르면 차이로 나온다).
  - bluesky 앱: `destination`은 `name: in-cluster`, `namespace: default`만 있다(`server` 없음). `project: default`.
  - opensource 앱: `destination`은 `namespace: opensource`, `server: https://kubernetes.default.svc`. `project: opensource`.
  - 모든 앱: `syncPolicy.automated`에 `prune: false`, `selfHeal: false`. `sources: []` 같은 빈 필드는 없다.
- **렌더에만 있음**: 등록하면 그 앱이 새로 생기고 auto sync로 배포된다. **비어 있어야 한다.**
  opensource 앱이 나오면 1-1번에서 설치되지 않은 것에 `work`를 넣은 것이므로 뺀다.
  bluesky 앱이 나오면(이 PC에 없는 bluesky 앱) 사용자에게 묻고, 배포하지 않을 거라면 그 항목에 `envs: [home]`을 준다.
- **live 에만 있음**: 1-1번에서 빠뜨린 opensource 앱이 없는지 다시 본다. 계속 git으로 관리할 앱이면 `values.yaml` 목록에 넣고 `envs`에 `work`를 준다. 아니면 그대로 둔다.

git을 고쳤다면 2번을 다시 돌려 DIFF와 "렌더에만 있음"이 의도한 것만 남았는지 확인한다.
`helm template root argocd_application --set env=home` 결과가 고치기 전과 같은지도 비교한 뒤 커밋하고 `develop`에 push한다.
push가 거절되면 `git pull origin develop`(merge) 후 다시 push한다. rebase하지 않는다.

## 3. 루트 앱 등록과 확인

```bash
kubectl get pods -A --no-headers -o custom-columns=N:.metadata.name | sort > "$TEMP/aoa/pods-before.txt"
kubectl apply -n argocd -f bootstrap/root-work.yaml
kubectl -n argocd get application bluesky-root -o jsonpath='{.status.sync.status} {.status.health.status} {.status.operationState.phase}{"\n"}'
```

- 루트 앱이 `Synced Healthy Succeeded`가 될 때까지 기다린다. 오류가 나면 `.status.conditions`와 `.status.operationState.message`를 확인한다.
- 다시 2번 스크립트를 돌려 DIFF가 없는지 확인한다(이제 live가 렌더와 같아야 한다). "live 에만 있음"에 `bluesky-root`가 나오는 것은 정상이다.
- 자식 앱이 모두 Synced/Healthy인지 확인한다:
  `kubectl -n argocd get applications -o custom-columns=N:.metadata.name,S:.status.sync.status,H:.status.health.status`
- pod 목록을 비교한다. 2번에서 받아들이기로 한 차이나 새로 생긴 앱 말고는 바뀌면 안 된다.
  `kubectl get pods -A --no-headers -o custom-columns=N:.metadata.name | sort | diff "$TEMP/aoa/pods-before.txt" -`

## 4. 끝나면

- 사용자에게 보고한다: 등록 여부, 처리한 차이(앱 이름과 방법), 새로 생기거나 관리 밖에 남은 앱.
- 이후 이 PC에서도 Application 추가나 sync 정책 변경은 `argocd_application/values.yaml`을 고치고 push하면 반영된다.
  ArgoCD UI에서 Application spec을 직접 고치면 다음 sync 때 git 값으로 돌아갈 수 있다(루트 앱 `selfHeal`은 꺼져 있어 즉시 되돌리지는 않는다).
