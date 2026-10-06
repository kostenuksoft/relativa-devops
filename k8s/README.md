# Kubernetes

Маніфести Relativa для локального кластера minikube. Один файл — один об'єкт, усі об'єкти в namespace `relativa`.
Числовий префікс у назві файлу задає порядок застосування: namespace → конфігурація та RBAC → інфраструктура → міграції → сервіси → ingress.

## Вимоги

- Docker Desktop (WSL 2)
- [minikube](https://minikube.sigs.k8s.io/docs/start/) і `kubectl`
- [Headlamp](https://headlamp.dev) — офіційний веб-інтерфейс Kubernetes (SIG UI)
- Образи `ghcr.io/kostenuksoft/relativa-*` з тегами `1.0.0` і `1.1.0` (публікуються CI при пуші тегу `v*.*.*`)

## Запуск

```bash
scripts/k8s.sh up
scripts/k8s.sh demo
scripts/k8s.sh ui
scripts/k8s.sh down
```

| Команда  | Що робить |
|----------|-----------|
| `up`     | запускає minikube (драйвер docker), вмикає `metrics-server` та `ingress`, показує вузол і поди `kube-system`, застосовує `k8s/` однією командою, чекає готовності, виводить поди / Deployment / ReplicaSet / Service і робить запит до gateway всередині кластера |
| `config` | показує змінні оточення контейнера, отримані з ConfigMap і Secret (секрети замасковані) |
| `demo`   | самовідновлення, масштабування з розподілом запитів між репліками, rolling update на `1.1.0` з перевіркою доступності, історія та відкат, `ImagePullBackOff` з описом пода, подіями, логами, exec і виправленням |
| `ui`     | відкриває Headlamp з поточним контекстом kubectl |
| `down`   | видаляє всі об'єкти з `k8s/` |

Параметри скрипта перевизначаються змінними оточення: `NAMESPACE`, `MINIKUBE_CPUS`, `MINIKUBE_MEMORY`, `DEMO_DEPLOYMENT`, `SCALE_REPLICAS`, `UPDATE_TAG`, `MISSING_TAG`, `ROLLOUT_TIMEOUT` тощо.

## Доступ з браузера

```bash
minikube tunnel
```

Додати у файл hosts (`127.0.0.1` для Windows / macOS, `minikube ip` для Linux):

```
127.0.0.1 relativa.local
127.0.0.1 api.relativa.local
```

- клієнт — http://relativa.local
- API та Scalar — http://api.relativa.local/scalar

## ConfigMap `relativa-config`

| Ключ | Значення | Використовують |
|------|----------|----------------|
| `ASPNETCORE_ENVIRONMENT` | `Development` | auth, core, graph, audit, gateway |
| `DB_HOST` | `postgres` | усі сервіси з БД, migration |
| `DB_PORT` | `5432` | усі сервіси з БД, migration |
| `DB_NAME` | `relativa` | postgres, усі сервіси з БД, migration |
| `DB_USER` | `relativa` | postgres, усі сервіси з БД, migration |
| `RABBITMQ_HOST` | `rabbitmq` | auth, core, graph, audit, ml |
| `RABBITMQ_PORT` | `5672` | auth, core, graph, audit, ml |
| `RABBITMQ_USER` | `relativa` | rabbitmq, auth, core, graph, audit, ml |
| `JWT_ISSUER` | `relativa-auth` | auth, audit, gateway |
| `JWT_AUDIENCE` | `relativa` | auth, audit, gateway |
| `SMTP_HOST` | `mailhog` | auth |
| `SMTP_PORT` | `1025` | auth |
| `CLIENT_ALLOWED_HOSTS` | `client,relativa.local` | client (`VITE_ALLOWED_HOSTS`): ім'я Service і хост ingress |
| `CLIENT_PUBLIC_URL` | `http://relativa.local` | auth (посилання в листах), gateway (CORS) |
| `GATEWAY_PUBLIC_URL` | `http://api.relativa.local` | client (`VITE_GATEWAY_URL`), gateway |
| `AUTH_URL`, `CORE_URL`, `GRAPH_URL`, `ML_URL`, `AUDIT_URL` | `http://<service>:<port>` | gateway (YARP), graph (`ML_URL`) |

## Secret `relativa-secrets`

| Ключ | Використовують |
|------|----------------|
| `DB_PASSWORD` | postgres, усі сервіси з БД, migration |
| `RABBITMQ_PASSWORD` | rabbitmq, auth, core, graph, audit, ml |
| `JWT_SECRET_KEY` | auth, audit, gateway |

Рядок підключення `ConnectionStrings__Default` збирається в Deployment із ключів ConfigMap і `DB_PASSWORD` через підстановку `$(VAR)`, тому пароль зберігається лише в Secret.
Значення в `02-secret.yaml` — локальні, для робочих середовищ їх не використовувати.

## Міграції

Job `migration` застосовує міграції БД. Сервіси з доступом до БД (auth, core, graph, audit, ml) стартують лише після його завершення: init-контейнери з образом `registry.k8s.io/kubectl` виконують `kubectl wait` для Job від імені ServiceAccount `migration-reader`, якому Role дозволяє лише читати Job.

## Репліки

`auth`, `audit`, `ml`, `gateway`, `client` — по 2 репліки, оновлення з `maxUnavailable: 0`.
`core` і `graph` — 1 репліка: їхні SignalR-хаби надсилають події лише клієнтам, підключеним до того самого пода, а backplane поки немає.
