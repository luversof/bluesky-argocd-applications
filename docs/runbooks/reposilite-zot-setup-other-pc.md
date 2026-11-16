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

## 방식: 주소는 프로젝트 git(pom)에, Jenkins에는 자격 증명만

주소는 Jenkins 설정으로 덮어쓰지 않고 pom에 둔다(2026-11-16 결정).
pom 6곳의 CI 프로필 주소를 바꾸고, 프로필 id를 `nexus-k8s` → `k8s-ci`로 바꿨다(이 6곳 + bluesky-cloud 하위 모듈 4곳. 하위 모듈에서는 jib를 켜는 역할).

| pom | 바뀐 것 |
|---|---|
| `bluesky-boot/bluesky-boot-build/bluesky-boot-dependencies/pom.xml` | 아래 3가지 + `build.image` `nexus-service:8083/luversof` → `zot-service:5000/luversof` |
| `bluesky-boot-connectioninfo/bluesky-boot-connectioninfo-dependencies/pom.xml`, `bluesky-boot-crypto/pom.xml`, `bluesky-boot-devcheck/bluesky-boot-devcheck-dependencies/pom.xml`, `bluesky-cloud/bluesky-cloud-parent/pom.xml`, `bluesky-project/bluesky-parent/pom.xml` | 읽기 저장소 `bluesky-nexus-k8s` → `reposilite-public` (`http://reposilite-service:8080/public/`), deploy `bluesky-releases`/`bluesky-snapshots` → `reposilite-releases`/`reposilite-snapshots` (`http://reposilite-service:8080/releases/`, `/snapshots/`) |

`build.image`는 bluesky-cloud·bluesky-project가 부모 `bluesky-boot-dependencies`(SNAPSHOT)에서 물려받는다. 그래서 bluesky-boot를 먼저 deploy해야 cloud·project가 zot으로 push한다.

**pom은 두 PC가 공유한다.** 이 pom이 push된 뒤에는 어느 PC의 Jenkins든 Reposilite·zot으로 deploy·push하므로, 그 PC에서 아래 0~4를 마친 뒤에 CI를 돌린다.
개발 PC용 주소도 바꿨다.
- `nexus-local` 프로필(bluesky-boot-dependencies, bluesky-cloud-parent) → 이름 `local`, 주소 `http://reposilite.bluesky.local/public/`·`/releases/`·`/snapshots/`, id `reposilite-public`·`reposilite-releases`·`reposilite-snapshots`.
- 항상 켜진 저장소 `bluesky-snapshots`(bluesky-cloud-parent, bluesky-parent) → id `reposilite-snapshots`, `http://reposilite.bluesky.local/snapshots/`.
  CI pod에서는 이 주소가 풀리지 않아 `Failed to transfer` 로그가 남지만 빌드는 진행된다(Nexus 때와 같음).
이제 pom 어디에도 Nexus 주소가 없다.

쓰이지 않던 `nexus-docker` 프로필(docker-compose 시절 `nexus:8081`)은 bluesky-boot-dependencies·bluesky-cloud-parent·bluesky-parent에서 지웠다.

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
   먼저 백업(`cp -p settings.xml settings.xml.bak-<날짜>`) 후 `<servers>`에 추가:
   `reposilite-releases`, `reposilite-snapshots` (username `jenkins`, password = jenkins 토큰 비밀값). id는 pom의 deploy 저장소 id와 같아야 한다.
2. 주소는 pom에 있으므로 mirror나 job goals 덮어쓰기는 넣지 않는다.
   job goals의 `-Pnexus-k8s`만 `-Pk8s-ci`로 바꾼다(6개: `bluesky-boot`, `bluesky-boot-connectioninfo`, `bluesky-boot-crypto`, `bluesky-boot-devcheck`, `bluesky-cloud`, `bluesky-project`의 `* ci develop`).
   pom push와 같은 때에 바꾼다. 어긋나면 그 사이 CI는 프로필 없이 돌아 deploy 대상이 없어 실패한다.
   zot은 인증이 없어 docker용 server 항목도 필요 없다(기존 `nexus-service:8083` server 항목은 쓰이지 않는다).

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

이미지 주소(4절)를 먼저 바꾼 뒤 CI를 돌린다. 반대로 하면 `update argocd manifest`가 새 buildNumber를 커밋할 때 주소가 아직 Nexus라
새 pod가 Nexus에 없는 태그를 찾아 ImagePullBackOff가 된다(work PC에서 겪음. 기존 pod는 살아 있어 서비스는 안 끊긴다).

1. `bluesky-boot ci develop` → Reposilite `snapshots`에 deploy되는지(콘솔 `Uploaded to reposilite-snapshots`). 바뀐 `build.image`가 이때 배포된다.
2. `bluesky-boot-connectioninfo`, `-crypto`, `-devcheck`.
3. `bluesky-cloud ci develop`, `bluesky-project ci develop` → jib가 `zot-service:5000`에 push(콘솔에서 확인), `update argocd manifest` job이 buildNumber 커밋 → ArgoCD가 새 태그를 zot에서 pull.

## 6. 남은 일(두 PC 모두 전환한 뒤)

- Jenkins settings.xml의 Nexus server 항목(`bluesky-releases`, `bluesky-snapshots`, `nexus-service:8083`) 제거.
- Nexus 앱 제거(`argocd_application/values.yaml`에서 `nexus` 삭제).
- 개발 PC에서 `-Plocal`로 deploy하려면 `~/.m2/settings.xml`에 server `reposilite-releases`·`reposilite-snapshots`(Reposilite 토큰 이름·비밀값)를 넣는다. 개발 PC용 토큰은 아직 만들지 않았다(`jenkins` 토큰처럼 `/releases`·`/snapshots` `r`,`w` 경로 권한으로 만든다).
- Reposilite 데이터 백업 CronJob(현재 없음).
