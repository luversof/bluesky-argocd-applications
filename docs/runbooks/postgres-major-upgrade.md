# PostgreSQL 메이저 업그레이드

PostgreSQL은 메이저 버전이 바뀌면 이전 데이터 디렉터리를 읽지 못한다.
그래서 새 버전을 옆에 띄우고 데이터를 옮긴 뒤 옛 버전을 지운다.

## 구조

`opensource/postgres` 차트 하나가 ArgoCD 앱 `postgres` 하나로 모든 버전을 배포한다.

- `versions`: 버전마다 `postgres-<major>-*`(Secret, PVC, Deployment, Service, 백업 CronJob)가 생긴다.
  - 접속 주소: `postgres-<major>-service.opensource:54<major>`, 클러스터 밖에서는 `postgres.bluesky.local:54<major>`.
- `active`: 고정 주소 `postgres-service.opensource:5432`(Secret `postgres-secret`)가 이 버전의 pod를 가리킨다.
  - 클러스터 밖에서는 `postgres.bluesky.local:5432`.
- 앱, connection_info, config-server, sonarqube는 고정 주소만 쓴다. 그래서 업그레이드 때 이쪽 설정은 바꾸지 않는다.

`active`를 바꾸면 모든 앱이 한꺼번에 새 버전으로 넘어간다.
특정 앱을 먼저 시험하려면, 그 앱만 버전별 주소로 잠깐 붙인다.

## 순서 (예: 19 → 20)

두 PC가 DB를 따로 쓰므로, 아래 4~7단계는 PC마다 한다.

1. `opensource/postgres/values.yaml`의 `versions`에 20을 더한다. `active`는 19로 둔다.
   ```yaml
   versions:
     - major: "19"
       image: postgres:19.0
     - major: "20"
       image: postgres:20.0
   active: "19"
   ```
2. push한다. `postgres` 앱이 auto sync로 `postgres-20-*`를 띄운다. 그 PC에서 sync가 안 됐으면 ArgoCD에서 refresh한다.
3. 다음 단계에서 쓰기를 멈출 수 있도록 시간을 정한다.
   - ArgoCD가 replicas를 되돌리므로 앱을 0으로 내려도 다시 올라온다.
   - 그래서 쓰기가 적은 시간에 복사하고, 복사한 뒤 차이가 생겼으면 그 부분만 다시 넣는다.
4. 데이터를 복사한다. 새 버전의 클라이언트로 옛 서버를 덤프한다.
   ```sh
   kubectl -n opensource exec deploy/postgres-20-deployment -- sh -c \
     'export PGPASSWORD="$POSTGRES_PASSWORD"; pg_dumpall -h postgres-19-service -p 5419 -U "$POSTGRES_USER" --no-role-passwords | psql -U "$POSTGRES_USER" -d postgres -q'
   ```
   - `role "root" already exists`와 `database "root" already exists` 오류는 정상이다.
5. 검증한다. DB마다 테이블별 행 수를 19와 20에서 비교한다.
   - 다르면, 그 테이블만 `pg_dump --data-only -t ... --inserts --on-conflict-do-nothing`으로 다시 넣는다.
   - 끝나면 `vacuumdb --all --analyze-only`를 실행한다.
6. `active`를 20으로 바꾸고 push한다.
   - `postgres-service`의 selector가 20으로 바뀐다.
   - 앱(`bluesky-api-*`, `bluesky-web-*`, config-server, sonarqube)을 재시작해 연결을 다시 맺게 한다.
7. 19에 연결이 남았는지 확인한다(`pg_stat_activity`). 그다음 마지막 백업을 뜬다.
   ```sh
   kubectl -n opensource create job postgres-19-backup-final --from=cronjob/postgres-19-backup
   ```
8. `versions`에서 19를 빼고 push한다.
9. PC마다 19 리소스를 직접 지운다. 앱이 `prune: false`라서 push만으로는 지워지지 않는다.
   ```sh
   kubectl -n opensource delete deploy/postgres-19-deployment service/postgres-19-service \
     secret/postgres-19-secret cronjob/postgres-19-backup job/postgres-19-backup-final
   kubectl -n opensource delete pvc/postgres-19-local-pvc   # 데이터가 지워진다. 되돌릴 수 없다
   ```
   - 백업 파일은 `<backup 경로>/19/`에 남는다.

## 이 구조로 바꾸기 전 PC (2026-11-24 이전 구성)

이전 구성에는 앱 `postgres`(18, `postgres-deployment` 등)와 앱 `postgres-19`가 따로 있었다.
push 후 루트 앱이 sync되면 `postgres` 앱이 새 차트로 바뀐다. 이때 `postgres-service`와 `postgres-secret`는 19를 가리키게 된다.
남는 것은 직접 정리한다.

1. 18에 연결이 없는지 확인하고 마지막 백업을 뜬다.
   - `cronjob/postgres-backup`으로 job을 만들면 안 된다. 이 CronJob은 `postgres-service`를 덤프하는데,
     그 주소가 이미 19를 가리켜 18 클라이언트로는 버전이 맞지 않아 실패한다. 18 pod에서 직접 덤프한다.
   ```sh
   # work 는 /c/data/backup/postgres, home 은 /d/dev/data/backup/postgres
   kubectl -n opensource exec deploy/postgres-deployment -- pg_dumpall -U root \
     | gzip > /c/data/backup/postgres/postgres-18-final-$(date +%Y-%m-%d-%H%M).sql.gz
   ```
2. 18 리소스와 앱 `postgres-19`를 지운다. 앱에 finalizer가 없어서, 앱을 지워도 `postgres-19-*` 리소스는 남는다.
   ```sh
   kubectl -n opensource delete deploy/postgres-deployment ingress/postgres-ingress cronjob/postgres-backup
   kubectl -n argocd delete application postgres-19
   kubectl -n opensource delete pvc/postgres-local-pvc   # 18 데이터. 되돌릴 수 없다
   ```
   - 리소스의 추적 표시가 아직 `postgres-19`라서 `postgres` 앱이 OutOfSync(SharedResourceWarning)로 남는다.
     ArgoCD에서 `postgres` 앱을 한 번 sync하면 풀린다.
3. connection_info DB 두 곳의 주소를 고정 주소로 바꾼다.
   ```sql
   -- connection_info_k8sdev
   update "DataSourceConnectionConfig" set url = replace(url, 'postgres-19-service.opensource:5419', 'postgres-service.opensource:5432');
   -- connection_info_localdev
   update "DataSourceConnectionConfig" set url = replace(url, 'postgres.bluesky.local:5419', 'postgres.bluesky.local:5432');
   ```
4. ArgoCD에서 `postgres`, `sonarqube`, bluesky 앱이 Synced/Healthy인지 확인하고, bluesky 앱을 재시작한다.
