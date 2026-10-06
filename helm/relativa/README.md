# Helm-чарт relativa

Чарт розгортає той самий набір об'єктів, що й маніфести з [`k8s/`](../../k8s): PostgreSQL з PVC, RabbitMQ, MailHog, Job міграцій з ServiceAccount / Role / RoleBinding для очікування на нього, сервіси auth, core, graph, audit, ml, gateway, client та Ingress. Додатково — PVC для резервних копій БД.
Імена всіх об'єктів будуються з імені релізу (`<release>-relativa-<component>`, або `<release>-<component>`, якщо ім'я релізу вже містить `relativa`), тож чарт можна встановити кілька разів в один кластер.

## version і appVersion

| Поле | Значення | Що означає |
|------|----------|------------|
| `version` | `0.1.0` | версія самого чарта: змінюється, коли змінюються шаблони, `values.yaml` або структура чарта |
| `appVersion` | `1.1.0` | версія застосунку Relativa, тобто тег образів `ghcr.io/kostenuksoft/relativa-*` за замовчуванням |

Тег образу береться з `image.tag`, якщо його задано, інакше з `appVersion`. Оновлення застосунку без змін у шаблонах змінює лише `appVersion`; зміна шаблонів без нового релізу застосунку — лише `version`.

## Встановлення

```bash
helm install relativa helm/relativa --namespace relativa --create-namespace -f helm/relativa/values-dev.yaml
```

```bash
helm install relativa helm/relativa --namespace relativa --create-namespace -f helm/relativa/values-prod.yaml \
  --set-file secrets.dbPassword=./db-password \
  --set-file secrets.rabbitmqPassword=./rabbitmq-password \
  --set-file secrets.jwtSecretKey=./jwt-secret-key
```

У `values-prod.yaml` паролів немає: без них рендер завершується помилкою `secrets.<key> is required`.

## Скрипт

```bash
scripts/helm.sh up
scripts/helm.sh envs
scripts/helm.sh compare
scripts/helm.sh demo
scripts/helm.sh ui
scripts/helm.sh down
```

| Команда | Що робить |
|---------|-----------|
| `up` | запускає minikube, перевіряє чарт (`helm lint`), видаляє розгортання з `k8s/`, встановлює реліз з `values-dev.yaml` і виконує `status` |
| `lint` | `helm lint --strict` для значень за замовчуванням, dev і prod |
| `envs` | різниця між dev і prod без встановлення в кластер (`helm template` + `diff`) і демонстрація пріоритету значень |
| `compare` | кількість об'єктів кожного типу в `k8s/` і в згенерованих маніфестах чарта |
| `status` | перелік релізів, статус, значення релізу, секрети `sh.helm.release.v1.*`, у яких Helm зберігає стан, і об'єкти namespace |
| `demo` | оновлення через `--set image.tag`, оновлення з `values-prod.yaml`, історія ревізій і різниця значень, відкат до ревізії 1, хуки та створені ними резервні копії, Job міграцій, `helm test` |
| `ui` | відкриває Headlamp (реліз видно в розділі Apps / Helm) |
| `down` | `helm uninstall` і перевірка, що в namespace не залишилося об'єктів |

Параметри скрипта: `RELEASE`, `NAMESPACE`, `INSTALL_ENV`, `UPGRADE_ENV`, `SET_TAG`, `PRECEDENCE_KEY`, `PRECEDENCE_VALUE`, `ROLLOUT_TIMEOUT`, `MINIKUBE_CPUS`, `MINIKUBE_MEMORY`.

## Пріоритет значень

Від найнижчого до найвищого: `values.yaml` чарта → файли `-f` у порядку передачі (наступний перекриває попередній) → `--set` / `--set-string` / `--set-file`.
Наприклад, `gateway.replicaCount` дорівнює `1` у `values.yaml`, `2` з `-f values-prod.yaml` і `3` з `-f values-prod.yaml --set gateway.replicaCount=3`.

## Міграції, хук і тест

- `templates/migration-job.yaml` — Job міграцій з номером ревізії в імені (`<fullname>-migration-<revision>`). Кожне встановлення, оновлення і відкат створюють новий Job, попередній видаляється разом зі старою ревізією, а `helm uninstall` прибирає його разом з релізом. Сервіси з БД чекають на завершення саме цього Job через init-контейнери `kubectl wait`; Role дозволяє читати лише його.
- `templates/backup-job.yaml` — хук `pre-upgrade,pre-rollback`: перед кожним оновленням і відкатом робить `pg_dump` у PVC `<fullname>-backup` і залишає `backup.keep` останніх копій. Якщо резервна копія не вдалася, оновлення не виконується. Після успіху Job видаляється (`hook-succeeded`).
- `templates/tests/test-connection.yaml` — под з `helm.sh/hook: test`, який перевіряє health-ендпоінти всіх сервісів через їхні Service; запуск — `helm test relativa --namespace relativa --logs`. Після успішного тесту под видаляється.

## Значення

| Ключ | За замовчуванням | dev | prod | Опис |
|------|------------------|-----|------|------|
| `image.repository` | `ghcr.io/kostenuksoft/relativa` | | | префікс образів, до нього додається `-<component>` |
| `image.tag` | `""` (= `appVersion`) | `1.1.0` | `1.0.0` | тег образів застосунку |
| `image.pullPolicy` | `IfNotPresent` | `IfNotPresent` | `Always` | політика завантаження образів |
| `<component>.image.repository`, `<component>.image.tag` | — | | | перевизначення образу окремого сервісу |
| `<component>.replicaCount` | `1` | `1` | `2` для auth, audit, ml, gateway, client | кількість реплік |
| `<component>.port` | порт сервісу | | | порт контейнера і Service |
| `<component>.service.type` | `ClusterIP`, gateway і client — `NodePort` | | | тип Service |
| `<component>.healthPath` | `/health`, graph і client — `/`, ml — `/api/ml/health/` | | | шлях readiness-проби і `helm test` |
| `<component>.resources` | див. `values.yaml` | мінімальні | збільшені | requests / limits CPU і пам'яті |
| `<component>.probes` | — | | | перевизначення `probes` для сервісу |
| `probes.readiness`, `probes.liveness` | `5s/10s`, `20s/20s` | | | затримка і період проб |
| `rollingUpdate` | `maxSurge: 1`, `maxUnavailable: 0` | | | стратегія оновлення Deployment |
| `config.aspnetcoreEnvironment` | `Development` | `Development` | `Production` | `ASPNETCORE_ENVIRONMENT` .NET-сервісів |
| `config.jwt.issuer`, `config.jwt.audience` | `relativa-auth`, `relativa` | | | параметри JWT |
| `publicUrls.client`, `publicUrls.gateway` | `http://localhost:3000`, `http://localhost:8080` | | | адреси для браузера без Ingress (port-forward) |
| `ingress.enabled` | `false` | `false` | `true` | створення Ingress; адреси для браузера беруться з `ingress.hosts` |
| `ingress.className`, `ingress.scheme`, `ingress.annotations` | `nginx`, `http`, таймаути для SignalR | | | налаштування Ingress |
| `ingress.hosts.client`, `ingress.hosts.gateway` | `relativa.local`, `api.relativa.local` | | | хости Ingress (ключ — назва компонента) |
| `secrets.dbPassword`, `secrets.rabbitmqPassword`, `secrets.jwtSecretKey` | локальні значення | | порожні, обов'язкові | значення Secret |
| `postgres.persistence.enabled` | `true` | | | PVC для PostgreSQL (інакше `emptyDir`) |
| `postgres.persistence.size` | `2Gi` | `1Gi` | `10Gi` | розмір PVC |
| `postgres.database`, `postgres.username`, `postgres.port` | `relativa`, `relativa`, `5432` | | | параметри БД |
| `rabbitmq.username`, `rabbitmq.port`, `rabbitmq.managementPort` | `relativa`, `5672`, `15672` | | | параметри брокера |
| `mailhog.smtpPort`, `mailhog.httpPort` | `1025`, `8025` | | | порти MailHog |
| `migration.backoffLimit` | `4` | | | кількість повторів Job міграцій |
| `migration.waitTimeout` | `10m` | | | скільки сервіси чекають на завершення міграцій |
| `migrationReaderImage` | `registry.k8s.io/kubectl:v1.37.0` | | | образ init-контейнерів, що чекають на міграції |
| `backup.enabled` | `true` | | | хук резервного копіювання і PVC для копій |
| `backup.keep` | `5` | | | скільки останніх копій зберігати |
| `backup.persistence.size` | `2Gi` | | | розмір PVC для копій |
| `waitImage`, `tests.image` | `busybox:1.37`, `curlimages/curl:8.16.0` | | | образи init-контейнерів і тесту |
| `imagePullSecrets` | `[]` | | | секрети для приватного registry |
