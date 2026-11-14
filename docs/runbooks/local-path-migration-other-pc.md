# 다른 PC: D:\·C:\ hostPath → local-path 이전 후속 작업

이슈 #2~#8(2026-11-14)에서 데이터 PV를 Windows 9p hostPath에서 VM 내부 `local-path` PVC로 옮겼다.
차트는 git(`develop`)에 반영되어 있으므로, 다른 PC의 ArgoCD가 sync하면 **새 PVC는 비어 있는 상태로 생성되고 앱이 빈 데이터로 기동한다.**
원본 데이터는 그 PC의 `C:\data\<이름>`(`/mnt/c/data/<이름>`)에 그대로 남아 있다. hostPath이고 PV가 `Retain`이므로 sync나 prune으로 지워지지 않는다.
이 문서는 그 PC에서 원본을 새 PVC로 옮기고 설정을 다시 맞추는 절차다.

## 0. 먼저 지킬 것

- **git에 `replicas: 0` 같은 임시 커밋을 하지 않는다.** git은 두 PC가 공유하므로 다른 PC의 서비스까지 멈춘다.
  서비스를 멈출 때는 그 PC의 ArgoCD에서 해당 앱의 **auto-sync를 끄고**(UI의 App Details → Disable Auto-Sync, git에는 반영하지 않음) `kubectl scale --replicas=0`을 쓴다.
  auto-sync를 끄지 않으면 다른 커밋(CI의 buildNumber 커밋 등)으로 sync가 돌 때 replicas가 1로 돌아와, 복사 중에 앱이 다시 뜬다(이 PC에서 Nexus로 겪음).
- 작업이 끝나면 auto-sync를 다시 켠다. git의 replicas는 1이다.
- 원본 `C:\data\*`는 지우지 않는다. 롤백할 일이 생길 때 필요하다.
- 시작 전에 상태를 확인한다: `kubectl -n opensource get pvc`에 `*-local-pvc`가 생겼는지, 앱 pod가 새 PVC로 이미 떴는지. 이미 빈 데이터로 떴다면 그 사이 생긴 데이터(빈 스키마 등)는 덮어써도 된다.
- 복사는 앱을 멈춘 상태에서 임시 pod로 한다. 공통 형태:

```yaml
apiVersion: v1
kind: Pod
metadata: {name: <x>-copy, namespace: opensource}
spec:
  restartPolicy: Never
  containers:
  - name: c
    image: busybox            # 서비스에 따라 다름 (아래 참고)
    command: ["sh","-c","set -e; cp -a /old/. /new/ && du -sh /old /new"]
    securityContext: {runAsUser: 0}
    volumeMounts: [{name: old, mountPath: /old, readOnly: true},{name: new, mountPath: /new}]
  volumes:
  - {name: old, hostPath: {path: /mnt/c/data/<원본 폴더>}}
  - {name: new, persistentVolumeClaim: {claimName: <새 PVC>}}
```

  새 PVC가 이미 빈 데이터로 초기화됐다면 먼저 비운다 (`find /new -mindepth 1 -delete` 후 복사).

## 1. Jenkins (데이터 유실 없음)

- workspace와 `.m2`가 `jenkins-workspace-local-pvc`, `jenkins-m2-local-pvc`로 바뀐다. workspace는 git clone으로, `.m2`는 Nexus에서 다시 채워진다. 복사는 선택이다(첫 빌드가 느린 것을 피하려면 `C:\data\jenkins-m2\repository`를 `jenkins-m2-local-pvc`로 복사).
- **Job 설정은 git에 없으므로 직접 바꾼다**: `bluesky-project » bluesky-project ci develop`의 goals에서 `-DskipTests` → `-Dmaven.test.skip=true`. (다른 ci job도 같은 goals면 같이)
- 예전 workspace `C:\data\jenkins-home\workspace`는 더 이상 쓰이지 않는다.

## 2. Nexus (가장 먼저: CI와 이미지 pull이 의존)

1. auto-sync 끄고 `nexus-deployment` replicas 0.
2. `/nexus-data`를 `nexus-data-local-pvc`로 복사. **blob 전체를 복사하지 말고 DB가 참조하는 blob만** 복사한다(이 PC에서는 175G 중 약 140G가 DB에 없는 고아 blob이었다). 절차:
   - 임시 pod 이미지 `sonatype/nexus3:latest`, root, `/old`=hostPath `/mnt/c/data/nexus-data`(read-only), `/new`=새 PVC.
   - `blobs/default/content`와 `tmp`를 뺀 나머지를 `tar`로 복사.
   - 복사한 `/new/db/nexus.mv.db`에서 참조 blob 목록을 뽑는다. H2 jar는 Nexus jar 안에 있다:
     `unzip -o -q -j /opt/sonatype/nexus/bin/sonatype-nexus-repository-*.jar "BOOT-INF/lib/h2-2*.jar" -d /work`
     `java -cp h2.jar org.h2.tools.RunScript -url jdbc:h2:file:/new/db/nexus -user "" -password "" -script q.sql -showResults`
     `SELECT TABLE_NAME FROM INFORMATION_SCHEMA.COLUMNS WHERE COLUMN_NAME='BLOB_REF'`로 테이블을 찾고, 모든 테이블의 `BLOB_REF`를 `CSVWRITE`로 내보낸다. 값 형식은 `default@<uuid>[@<날짜>]`.
   - `find /old/blobs/default/content -type f` 목록에서 파일 이름(`<uuid>.bytes`, `<uuid>.properties`)이 참조 uuid인 것만 `tar -T`로 복사. 확인: 복사한 파일 수 = 참조 수 × 2, 누락 uuid 0.
   - `chown -R 200:200 /new`.
3. auto-sync 켜고 기동 확인: `https://nexus.bluesky.local/service/rest/v1/status/writable` 200.
4. Nexus 설정은 그 PC의 Nexus DB에 있으므로 다시 만든다 (관리자 로그인 필요. 브라우저 세션으로 REST 호출 가능):
   - cleanup policy `docker-hosted-14d` (format docker, Component Age 14일) — CE에는 공개 API가 없어 UI로 생성, docker-hosted에 연결(`PUT /service/rest/v1/repositories/docker/hosted/docker-hosted`의 `cleanup.policyNames`)
   - 작업(`POST /service/rest/v1/tasks`, cron은 UTC):
     - `repository.maven.remove-snapshots`: maven-snapshots, minimumRetained 1, snapshotRetentionDays 14, `0 0 2 * * ?`
     - `repository.docker.gc`: docker-hosted, `0 0 3 * * ?`
     - `blobstore.compact`: default, `0 0 4 * * ?`
     - `h2.backup.task`: location `/nexus-backup`, `0 0 18 * * ?` — 실행해서 `C:\data\backup\nexus`에 zip이 생기는지 확인
   - 기존 `Cleanup service`를 한 번 실행하고, docker gc → snapshot 삭제 → compact 순으로 돌려 정리.
5. CI 빌드 한 번 실행(Maven deploy, jib push 성공) + 앱 이미지 pull 확인.

## 3. postgres

1. auto-sync 끄고 replicas 0. 정상 종료 확인(로그 `database system is shut down`).
2. 이미지 `postgres:18.4`로 `cp -a /mnt/c/data/postgres/. → postgres-local-pvc`, 이후 `chown -R 999:999 /new && chmod 700 /new`.
3. auto-sync 켜고 기동, 앱 health 확인.
4. `postgres-backup` CronJob을 한 번 실행(`kubectl create job --from=cronjob/postgres-backup ...`)해 `C:\data\backup\postgres`에 파일이 생기는지 확인.

## 4. mariadb (파일 복사 금지: dump/복원)

C:\(9p)는 대소문자를 구분하지 않아 기존 서버는 `lower_case_table_names=2`(자동)로 돌았다. 새 서버는 `--lower-case-table-names=1`로 초기화된다. **데이터 파일을 그대로 복사하면 InnoDB 이름이 어긋나므로 dump/복원으로 옮긴다.**

1. auto-sync 끄고 replicas 0.
2. 원본을 임시 pod로 띄운다: 이미지 `mariadb`, `MARIADB_ROOT_PASSWORD`는 `mariadb-secret`에서, `/var/lib/mysql`=hostPath `/mnt/c/data/mariadb`.
   - 이미지(latest)가 13.x이고 시스템 테이블이 이전 버전이면 `--routines` dump가 `Column count of mysql.proc is wrong`로 실패한다. 이때 `mariadb-upgrade -uroot -p...`를 먼저 실행한다.
   - `mariadb-dump --all-databases --single-transaction --routines --events --triggers | gzip > /backup/mariadb-migration.sql.gz` (`/backup`=hostPath `/mnt/c/data/backup/mariadb`)
   - 비교용으로 사용자 테이블 `CHECKSUM TABLE ... EXTENDED` 결과를 저장(이름은 소문자로 맞춰 비교).
   - pod 삭제(정상 종료).
3. 새 PVC를 임시 pod로 띄운다: 같은 이미지, args `--character-set-server=utf8mb4 --collation-server=utf8mb4_unicode_ci --lower-case-table-names=1`, `/var/lib/mysql`=`mariadb-local-pvc`(이미 초기화돼 있으면 비우고 시작). dump를 복원하고 checksum 비교 후 pod 삭제.
4. auto-sync 켜고 기동, `select @@lower_case_table_names` = 1, 앱 health(`db: UP`) 확인.
5. `mariadb-backup` CronJob 한 번 실행해 확인.

## 5. mongo

1. auto-sync 끄고 replicas 0. `/mnt/c/data/mongo/mongod.lock`이 0바이트(정상 종료)인지 확인.
2. 이미지 `mongo`로 `cp -a` → `mongo-local-pvc`, `chown -R 999:999 /new`.
3. auto-sync 켜고 기동, `dbHash` 비교. `mongo-backup` CronJob 한 번 실행.

## 6. mssql

1. auto-sync 끄고 replicas 0 (Recreate 전략이 이미 들어 있다).
2. `cp -a /mnt/c/data/mssql-data/. → mssql-data-local-pvc`, `/mnt/c/data/mssql-log/. → mssql-log-local-pvc`. secrets는 C:\ 그대로.
   (`mssql-backup-staging-local-pvc`도 같은 pod에 마운트해 두면 바인딩된다.)
3. auto-sync 켜고 기동(`Recovery is complete`), 사용자 DB 행 수 비교.
4. `mssql-backup` CronJob 한 번 실행. SQL Server는 9p에 백업 파일을 쓰지 못하므로 staging PVC에 쓰고 CronJob이 `C:\data\backup\mssql`로 옮기는 구조다.

## 7. seaweedfs, sonarqube, prometheus (선택)

- seaweedfs: loki 로그와 tempo 트레이스 버킷뿐이다. 이력을 유지하려면 `/mnt/c/data/seaweedfs-data` → `seaweedfs-data-local-pvc` 복사, 아니면 빈 상태로 둬도 된다.
- sonarqube-data: Elasticsearch 인덱스만 있다(분석 데이터는 postgres). 빈 상태로 떠도 인덱스를 다시 만든다. 복사하면 기동이 빠르다.
- prometheus: 지표 이력(15일 보관). 필요하면 복사.
- loki-data는 바뀌지 않았다(쓰이지 않는 PV).

## 8. 마무리

- ArgoCD에서 각 앱의 기존 PV/PVC prune: `nexus-data`, `postgres`, `mariadb`, `mongo`, `mssql-data`, `mssql-log`, `seaweedfs-data`, `sonarqube-data`, `prometheus-data`, `jenkins-m2`
- 모든 앱 auto-sync가 다시 켜져 있는지 확인.
- CI 빌드 한 번 실행해 시간 확인(이 PC 기준 26분 → 약 3~4분).
