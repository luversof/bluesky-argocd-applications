# 0001. Nexus 내부 통신은 HTTP로 유지한다

- 상태: 채택
- 날짜: 2026-11-14
- 관련 이슈: #1

## 배경

Nexus는 두 포트를 HTTP로 제공한다.

- Maven 저장소: `nexus-service:8082` (클러스터 내부), `nexus.bluesky.local` (Traefik ingress)
- Docker registry: `nexus-service:8083` (Jenkins jib push), `nexus.bluesky.local:8083` (k8s 이미지 pull)

이 때문에 Jenkins job에 `-Djib.allowInsecureRegistries=true -DsendCredentialsOverHttp=true`가 있고,
Rancher Desktop VM의 `/etc/docker/daemon.json`에 `insecure-registries`로 두 registry 주소가 등록되어 있다.

모든 서비스는 개발자 PC 한 대의 Rancher Desktop 안에서만 돌고, 이 PC 밖으로 노출되지 않는다.

## 결정

Nexus 내부 통신을 HTTPS로 바꾸지 않고 HTTP로 유지한다.
위 jib 옵션과 `insecure-registries` 설정은 의도된 것이다.

## 이유

HTTPS로 바꾸려면 ArgoCD가 관리하지 않는 설정을 여러 곳에서 바꾸고 계속 유지해야 한다.

- Rancher Desktop VM: docker가 mkcert CA를 신뢰하도록 `/etc/docker/certs.d` 설정이 필요하다. Rancher Desktop 업데이트나 리셋 때 사라질 수 있다.
- Jenkins: JDK cacerts에 mkcert CA를 넣어야 한다. `jenkins/jenkins:jdk25` 이미지를 받을 때마다 초기화되므로 기동 때마다 다시 넣어야 한다.
- CoreDNS: pod 안에서 `nexus.bluesky.local`을 Traefik으로 해석하도록 설정해야 한다.
- Jenkins Maven `settings.xml`, job goals, 각 PC의 `~/.m2/settings.xml`의 저장소 주소도 바꿔야 한다.

반면 얻는 것은 작다. 통신은 모두 이 PC 내부에서만 일어난다.

## 결과

- 감사나 리뷰에서 Nexus HTTP 통신, jib insecure 옵션, `insecure-registries`를 문제로 지적하지 않는다.
- 외부에 노출하거나 여러 PC가 한 Nexus를 공유하게 되면 이 결정을 다시 검토한다. 그때는 위 "이유"의 네 항목이 작업 목록이다.
