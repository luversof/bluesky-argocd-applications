# 0002. Reposilite·zot 내부 통신은 HTTP로 유지한다

- 상태: 채택
- 날짜: 2026-11-22
- 대체: [0001](0001-nexus-internal-http.md) (Nexus는 2026-11-16 work, 2026-11-18 home에서 제거)

## 배경

Nexus를 Reposilite(Maven)와 zot(Docker registry)으로 바꿨다. 둘 다 HTTP로 제공한다.

- Reposilite: `http://reposilite-service:8080` (클러스터 내부), `reposilite.bluesky.local` (Traefik ingress). 쓰기는 토큰 인증.
- zot: `zot-service:5000` (Jenkins jib push), `zot.bluesky.local:5000` (k8s 이미지 pull). 인증 없음.

이 때문에 Jenkins ci job goals에 `-Djib.allowInsecureRegistries=true -DsendCredentialsOverHttp=true`가 있고,
Rancher Desktop VM의 `/etc/docker/daemon.json` `insecure-registries`에 `zot.bluesky.local:5000`이 등록되어 있다.

모든 서비스는 개발자 PC 한 대의 Rancher Desktop 안에서만 돌고, 이 PC 밖으로 노출되지 않는다.

## 결정

Reposilite와 zot 내부 통신을 HTTPS로 바꾸지 않고 HTTP로 유지한다. zot에는 인증을 넣지 않는다.
jib insecure 설정과 `insecure-registries` 설정은 의도된 것이다.

## 이유

0001과 같다. HTTPS로 바꾸려면 ArgoCD가 관리하지 않는 설정을 여러 곳에서 바꾸고 계속 유지해야 한다.

- Rancher Desktop VM: docker가 mkcert CA를 신뢰하도록 `/etc/docker/certs.d` 설정이 필요하다. Rancher Desktop 업데이트나 리셋 때 사라질 수 있다.
- Jenkins: JDK cacerts에 mkcert CA를 넣어야 한다. `jenkins/jenkins:jdk25` 이미지를 받을 때마다 초기화되므로 기동 때마다 다시 넣어야 한다.
- CoreDNS: pod 안에서 `*.bluesky.local`을 Traefik으로 해석하도록 설정해야 한다.
- pom의 저장소 주소, Jenkins Maven `settings.xml`, 각 PC의 `~/.m2/settings.xml`도 바꿔야 한다.

반면 얻는 것은 작다. 통신은 모두 이 PC 내부에서만 일어난다.

## 결과

- 감사나 리뷰에서 Reposilite·zot HTTP 통신, zot 무인증, jib insecure 설정, `insecure-registries`를 문제로 지적하지 않는다.
- 외부에 노출하거나 여러 PC가 한 저장소를 공유하게 되면 이 결정을 다시 검토한다. 그때는 위 "이유"의 네 항목이 작업 목록이다.
