# 다른 PC: Nexus → Reposilite(Maven) + zot(Docker) 전환

2026-11-16 work PC에서 진행했다. home PC는 아래 절차를 그대로 하면 된다(경로·subchart 이름만 `home`으로 바꾼다).

## 배경

Nexus Community Edition 3.97+는 Sonatype으로 base telemetry 업로드를 강제하고, 30일 동안 실패하면 read-only가 된다.
work PC의 Nexus는 업로드가 HTTP 400으로 계속 거부됐고(동의는 되어 있었고 네트워크·TLS 문제도 아니었다), CE에는 끄는 설정이 없다.
그래서 Maven 저장소는 Reposilite, Docker registry는 zot으로 옮긴다. 둘 다 Apache-2.0이다.

| 용도 | Nexus | 대체 |
|---|---|---|
| Maven hosted | `maven-releases`, `maven-snapshots` | Reposilite `releases`, `snapshots` |
| Maven proxy + group | `maven-central`, `maven-public` | Reposilite `public` (proxied: `releases`, `snapshots`, Maven Central(store)) |
| Docker hosted | `docker-hosted` (`nexus-service:8083`, `nexus.bluesky.local:8083`) | zot (`zot-service:5000`, `zot.bluesky.local:5000`) |

zot도 Nexus와 같이 HTTP, 인증 없이 둔다(docs/adr/0001-nexus-internal-http.md와 같은 이유).

## 방식: git(pom)은 바꾸지 않고 Jenkins 쪽만 바꾼다

pom 10곳의 `nexus-k8s` 프로필(저장소 id `bluesky-nexus-k8s`, deploy id `bluesky-releases`/`bluesky-snapshots`, `build.image=nexus-service:8083/luversof`)은 그대로 둔다.
`nexus-k8s` 프로필은 bluesky-cloud 하위 모듈에서 jib를 켜는 역할도 하므로 job goals의 `-Pnexus-k8s`도 유지한다.
대신 Jenkins에서 덮어쓴다.

- 읽기: Jenkins Maven `settings.xml`의 mirror가 `bluesky-nexus-k8s`를 Reposilite `public`으로 돌린다.
- deploy: job goals에 `-DaltReleaseDeploymentRepository` / `-DaltSnapshotDeploymentRepository`.
- 이미지: job goals에 `-Dbuild.image=zot-service:5000/luversof`(pom 속성보다 명령줄이 우선).

PC마다 Jenkins가 따로라 한 PC씩 전환할 수 있고, 되돌릴 때는 goals와 settings.xml만 원래대로 하면 된다.
두 PC 모두 전환한 뒤 pom 정리(프로필 이름·URL 변경, Nexus 제거)를 한다.

## 0. 사전 조건

- `argocd_application/values.yaml`에 `reposilite`, `zot`이 `envs: [home, work]`로 들어 있다 → 루트 앱 sync로 두 앱이 이미 설치되어 있다.
  `kubectl -n opensource get pods | grep -E "reposilite|zot"` 둘 다 Running인지 확인.
- Windows hosts 파일(관리자): `nexus.bluesky.local`과 같은 IP로 `reposilite.bluesky.local`, `zot.bluesky.local` 추가.
- Rancher Desktop VM `/etc/docker/daemon.json`의 `insecure-registries`에 `"zot.bluesky.local:5000"` 추가 후,
  Rancher Desktop 재시작 없이 반영: `rdctl shell sudo kill -HUP $(rdctl shell pidof dockerd)`
  확인: `rdctl shell sh -c 'docker info 2>/dev/null | grep -A5 "Insecure Registries"'`
  확인: `rdctl shell docker pull zot.bluesky.local:5000/luversof/probe:none` → `not found`가 나오면 registry까지 닿은 것이다.

## 1. Reposilite 토큰과 저장소

Reposilite 콘솔(`kubectl attach`)은 Git Bash처럼 TTY가 없는 셸에서 `Error from server:`로 실패했다. 그래서 임시 토큰을 env로 넣고 API로 영구 토큰을 만든다.
비밀값은 git·채팅에 남기지 않는다(임시 파일에만 두고 끝나면 지운다).

1. 임시 토큰 주입:
   ```
   kubectl -n opensource create secret generic reposilite-bootstrap --from-literal=REPOSILITE_OPTS="--token bootstrap:<임의 비밀값>"
   kubectl -n opensource set env deploy/reposilite-deployment --from=secret/reposilite-bootstrap
   ```
2. `https://reposilite.bluesky.local` API에 Basic `bootstrap:<비밀값>`으로:
   - `PUT /api/tokens/admin` `{"type":"PERSISTENT","secretType":"RAW","secret":"<admin 비밀값>","permissions":["m"]}`
   - `PUT /api/tokens/jenkins` `{"type":"PERSISTENT","secretType":"RAW","secret":"<jenkins 비밀값>","permissions":[],"routes":[{"path":"/releases","permissions":["r","w"]},{"path":"/snapshots","permissions":["r","w"]}]}`
   - 권한 값은 짧은 코드다: 토큰 `m`(manager), 경로 `r`/`w`. `MANAGER`·`READ`/`WRITE`는 400.
   - `GET /api/settings/domain/maven` → `repositories`에 `releases`를 복사한 `public`을 추가하고 `proxied`를
     `[{"reference":"releases"},{"reference":"snapshots"},{"reference":"https://repo.maven.apache.org/maven2","store":true}]`로 → `PUT /api/settings/domain/maven`.
     (`reference`는 로컬 저장소 id 또는 원격 URL)
3. 임시 토큰 제거: `kubectl -n opensource set env deploy/reposilite-deployment REPOSILITE_OPTS-` 후 `kubectl -n opensource delete secret reposilite-bootstrap`. ArgoCD `reposilite`가 Synced로 돌아오는지 확인.
4. 확인: admin 토큰으로 `GET /api/tokens` → `admin`, `jenkins`만 있음. 익명 `GET /public/org/apache/commons/commons-lang3/3.17.0/commons-lang3-3.17.0.pom` → 200.
5. admin 비밀값은 웹 UI(`https://reposilite.bluesky.local`) 로그인용으로 따로 보관한다.

## 2. zot

설정은 git(`opensource/zot/templates/configmap.yaml`)에 있어 따로 할 일이 없다.
- `http.compat: ["docker2s2"]`가 필수다. 없으면 jib·docker가 보내는 Docker manifest를 `PUT manifest` 415(`manifest invalid`)로 거부한다.
- retention: 저장소마다 최근 push 태그 10개 유지(Nexus `docker-hosted-14d` cleanup 대체).

## 3. Jenkins

1. Maven 설정 파일: `/var/jenkins_home/tools/hudson.tasks.Maven_MavenInstallation/maven/conf/settings.xml`(jenkins-home PVC, 전역 설정 = 기본 provider).
   먼저 백업(`cp -p settings.xml settings.xml.bak-<날짜>`) 후 추가:
   - `<servers>`: `reposilite-releases`, `reposilite-snapshots` (username `jenkins`, password = jenkins 토큰 비밀값)
   - `<mirrors>`: `<mirror><id>reposilite-public</id><mirrorOf>bluesky-nexus-k8s</mirrorOf><url>http://reposilite-service:8080/public</url></mirror>`
   - mirror는 저장 즉시 모든 job에 적용된다.
2. job goals 뒤에 추가(config.xml POST, crumb 필요. 원본 config.xml은 먼저 백업):
   - 6개 모두: `-DaltReleaseDeploymentRepository=reposilite-releases::http://reposilite-service:8080/releases -DaltSnapshotDeploymentRepository=reposilite-snapshots::http://reposilite-service:8080/snapshots`
     (`bluesky-boot`, `bluesky-boot-connectioninfo`, `bluesky-boot-crypto`, `bluesky-boot-devcheck`, `bluesky-cloud`, `bluesky-project`의 `* ci develop`)
   - `bluesky-cloud`, `bluesky-project`에는 추가로 `-Dbuild.image=zot-service:5000/luversof`

## 4. 배포 중인 이미지를 zot으로 옮기고 이미지 주소 전환

이미지 주소를 바꾸기 전에 지금 태그를 zot에 넣어 두면 전환 때 pod가 같은 태그를 zot에서 받아 끊기지 않는다.
Nexus docker pull은 인증이 필요하지만, 배포 중인 이미지는 이미 노드에 있으므로 pull 없이 tag·push 한다.

```
kubectl get deploy -A -o jsonpath='{range .items[*]}{.spec.template.spec.containers[*].image}{"\n"}{end}' | grep -E "^nexus\.bluesky\.local:8083" | sort -u | rdctl shell sh -c 'cat > /tmp/imgs.txt'
rdctl shell sh -c 'while read i; do n=zot.bluesky.local:5000/${i#nexus.bluesky.local:8083/}; docker tag $i $n && docker push -q $n >/dev/null && echo "OK $n" || echo "FAIL $n"; done < /tmp/imgs.txt; rm -f /tmp/imgs.txt'
```

그다음 `bluesky-project_subchart/subchart_<env>/buildInfo-bluesky-project/values.yaml`, `buildInfo-bluesky-cloud/values.yaml`의
`host: nexus.bluesky.local:8083` → `host: zot.bluesky.local:5000` 을 커밋·push(사용자). ArgoCD sync 후 pod 이미지가 zot 주소로 바뀌고 정상 기동하는지 확인.

## 5. CI 확인 순서

1. `bluesky-boot ci develop` → Reposilite `snapshots`에 deploy되는지(콘솔 `Uploaded to reposilite-snapshots`).
2. `bluesky-boot-connectioninfo`, `-crypto`, `-devcheck`.
3. `bluesky-cloud ci develop`, `bluesky-project ci develop` → jib가 `zot-service:5000`에 push, `update argocd manifest` job이 buildNumber 커밋 → ArgoCD가 새 태그를 zot에서 pull.

## 6. 남은 일(두 PC 모두 전환한 뒤)

- pom 10곳의 `nexus-k8s` 프로필 정리와 `build.image` 기본값 변경, Jenkins goals의 덮어쓰기 옵션 제거.
- Nexus 앱 제거(`argocd_application/values.yaml`에서 `nexus` 삭제), PC별 개발자 `~/.m2/settings.xml` 저장소 주소 변경.
- Reposilite 데이터 백업 CronJob(현재 없음).
