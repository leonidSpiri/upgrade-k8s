# k8s-node-upgrade.sh

Безопасный пошаговый upgrade kubeadm-кластера Kubernetes на Linux node, плюс отдельный режим для jump host.

Скрипт запускается **локально на каждой машине**: на control-plane, worker или jump host. Он делает preflight-проверки, создаёт backup, обновляет Kubernetes **по одной minor-версии за шаг**, умеет обновлять `kubeadm`, `kubelet`, `kubectl`, переключать `pkgs.k8s.io` repo на нужную minor-ветку и, при желании, отдельно обновлять Helm.

> Скрипт рассчитан на **kubeadm + Linux + systemd + apt/yum/dnf/dnf5**.

---

## Что делает скрипт

На каждой node скрипт:

1. Определяет роль: `control-plane`, `worker` или `jump-host`.
2. Для `control-plane` и `worker` проверяет доступ к кластеру через `kubectl` и `kubeconfig`. Для `jump-host` `kubeconfig` опционален.
3. Определяет текущую версию `kubelet`.
4. Получает целевую версию:
   - либо из `--target vX.Y.Z`
   - либо автоматически из `https://dl.k8s.io/release/stable.txt`
5. Если требуется minor-upgrade, **идёт последовательно по всем промежуточным minor-версиям**.
6. Перед каждым шагом:
   - создаёт локальные backup'ы;
   - сохраняет метаданные для rollback;
   - на control-plane делает backup `/etc/kubernetes`;
   - на control-plane со stacked etcd создаёт `etcd` snapshot.
7. Для каждого upgrade-step на `control-plane` / `worker`:
   - переключает пакетный репозиторий на нужную minor-ветку `pkgs.k8s.io`;
   - обновляет `kubeadm`;
   - выполняет `kubeadm upgrade apply` или `kubeadm upgrade node`;
   - делает `drain` node;
   - обновляет `kubelet` и `kubectl`;
   - перезапускает `kubelet`;
   - ждёт `Ready`;
   - делает `uncordon`.
8. В режиме `jump-host` обновляет только `kubectl`. Если Kubernetes repo file отсутствует, скрипт сам создаёт официальный `pkgs.k8s.io` repo и keyring для нужной minor-ветки.
9. Если указан `--helm true`, отдельно обновляет Helm через официальный installer script.

---

## Что именно обновляется

Скрипт обновляет:

- `kubeadm`
- `kubelet`
- `kubectl`
- `pkgs.k8s.io` repo file на нужную minor-ветку
- APT keyring для `pkgs.k8s.io` на Debian/Ubuntu, если нужно
- control-plane компоненты через `kubeadm upgrade apply`
- worker node конфигурацию через `kubeadm upgrade node`
- только `kubectl` на `jump-host`
- Helm, если задан `--helm true`

---

## Что скрипт **не** обновляет

Это сделано специально, чтобы не вносить небезопасную автоматизацию туда, где у разных кластеров слишком много vendor-specific отличий.

Скрипт **не** обновляет автоматически:

- CNI plugin
- CSI drivers
- device plugins
- ingress-controller
- сторонние operators
- контейнерный runtime
- ОС и kernel
- ваши приложения, Helm charts и их values
- манифесты с deprecated API versions

После cluster upgrade это нужно проверять отдельно по документации конкретного компонента.

---

## Почему upgrade идёт по каждой minor-версии

Потому что для `kubeadm` **перескакивать через minor-версии нельзя**.

Официальная документация Kubernetes прямо говорит:

- `Skipping MINOR versions when upgrading is unsupported.`
- Документация на актуальный шаг описывает upgrade, например, **с 1.34.x на 1.35.x** и отдельно patch upgrade внутри той же minor-ветки.
- Для старых версий Kubernetes даёт отдельные upgrade-страницы: `1.33 -> 1.34`, `1.32 -> 1.33` и так далее.

Практический смысл такой:

- уменьшается риск несовместимости конфигов и API;
- соблюдается version skew policy;
- `kubeadm` ожидает именно поддерживаемую последовательность переходов;
- на `pkgs.k8s.io` пакеты разложены по **отдельным minor-репозиториям**, поэтому при каждом minor-upgrade нужно переключать repo.

Именно поэтому скрипт не пытается делать прыжок вида `1.31 -> 1.35`, а строит цепочку шагов:

```text
1.31.x -> 1.32.latest -> 1.33.latest -> 1.34.latest -> 1.35.latest
```

### Источники

- Kubernetes: Upgrading kubeadm clusters  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Kubernetes: Changing the Kubernetes package repository  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/

---

## Зачем нужен kubeconfig на worker

Скрипт запускается **локально на worker node**, но часть действий он делает **через Kubernetes API**, а не только локально в ОС.

В частности, скрипт вызывает:

- `kubectl get node`
- `kubectl drain <node>`
- `kubectl wait --for=condition=Ready node/...`
- `kubectl uncordon <node>`

Эти команды работают не “с локальной машиной напрямую”, а **с кластером через API server**. Поэтому `kubectl` должен знать:

- куда подключаться;
- как аутентифицироваться;
- какой CA использовать;
- какие права есть у пользователя.

Всё это хранится в `kubeconfig`.

Без `kubeconfig` worker не сможет:

- безопасно вывести себя из эксплуатации через `drain`;
- дождаться подтверждения `Ready` от кластера;
- вернуть себя обратно через `uncordon`.

То есть локально обновить пакеты на worker можно и без `kubeconfig`, но **безопасный orchestration upgrade в одном скрипте — уже нет**.

### Что говорит official docs

Официальная документация Kubernetes для upgrade Linux worker nodes говорит, что:

- `kubectl command-line tool must be configured to communicate with your cluster`
- для `kubectl` нужен `kubeconfig` file, через который он подключается к кластеру
- `kubectl drain` работает через API server: он делает node unschedulable и эвиктит Pod'ы

### Источники

- Kubernetes: Upgrading Linux nodes  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
- Kubernetes: kubectl drain  
  https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/
- Kubernetes: Organizing Cluster Access Using kubeconfig Files  
  https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Kubernetes: Troubleshooting kubectl  
  https://kubernetes.io/docs/tasks/debug/debug-cluster/troubleshoot-kubectl/

---

## Какой kubeconfig использовать на worker

### Самый простой вариант

Временно положить на worker root-only kubeconfig, который точно имеет нужные права.

Например:

```bash
sudo install -d -m 0700 /root/.kube
sudo cp /etc/kubernetes/admin.conf /root/.kube/admin.conf
sudo chmod 0600 /root/.kube/admin.conf
```

И запускать:

```bash
sudo ./k8s-node-upgrade.sh --role worker --kubeconfig /root/.kube/admin.conf
```

### Более аккуратный вариант

Использовать **отдельный kubeconfig** для upgrade-операций, а не `admin.conf`.

Это лучше с точки зрения безопасности, потому что можно:

- хранить отдельные учётные данные;
- ограничить срок жизни доступа;
- контролировать, где именно этот kubeconfig размещён.

### Важное замечание по безопасности

В official docs есть прямое предупреждение: **используй kubeconfig только из trusted sources**. Злоумышленный kubeconfig может привести к выполнению нежелательных действий или раскрытию файлов.

---

## Особенности режима jump-host

Режим `jump-host` нужен для машины, на которой установлен только `kubectl` и нет `kubelet` / `kubeadm`.

Что важно:

- `kubeconfig` для `jump-host` не обязателен;
- если `kubeconfig` передан, скрипт проверяет доступ к API server;
- если локальный `kubectl` слишком старый, `kubectl version` может вывести warning про unsupported version skew до обновления;
- если файла `/etc/apt/sources.list.d/kubernetes.list` нет, скрипт сам создаёт официальный repo `pkgs.k8s.io` для нужной minor-ветки;
- на Debian/Ubuntu скрипт также подтягивает официальный `Release.key` и формирует `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`.

Это поведение опирается на official install docs для `kubectl` на Linux и на version skew policy. `kubectl` поддерживается в пределах **±1 minor** относительно `kube-apiserver`. Например, при API server `1.35` поддержаны `kubectl` версий `1.34`, `1.35` и `1.36`. Если на jump host стоит `kubectl 1.32`, warning до обновления ожидаем и нормален.

### Источники

- Kubernetes: Install and Set Up kubectl on Linux  
  https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Kubernetes: Version Skew Policy  
  https://kubernetes.io/releases/version-skew-policy/
- Kubernetes: Changing the Kubernetes package repository  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/

---

## Порядок upgrade по ролям

Официальный порядок для кластера такой:

1. Первая control-plane node
2. Остальные control-plane nodes
3. Worker nodes

`jump-host` не участвует в последовательности cluster upgrade. Его можно обновить отдельно после обновления control-plane / worker, чтобы привести `kubectl` к совместимой версии.

### Первая control-plane

```bash
sudo ./k8s-node-upgrade.sh \
  --role control-plane \
  --first-control-plane true \
  --kubeconfig /etc/kubernetes/admin.conf
```

### Остальные control-plane

```bash
sudo ./k8s-node-upgrade.sh \
  --role control-plane \
  --first-control-plane false \
  --kubeconfig /etc/kubernetes/admin.conf
```

### Worker

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf
```

### Jump host

Без проверки against cluster:

```bash
sudo ./k8s-node-upgrade.sh --role jump-host
```

С проверкой against cluster:

```bash
sudo ./k8s-node-upgrade.sh --role jump-host --kubeconfig /root/.kube/config
```

---

## Как работает upgrade внутри скрипта

### Control-plane

На первой control-plane node:

- обновляется `kubeadm`
- выполняется `kubeadm upgrade plan`
- выполняется `kubeadm upgrade apply vX.Y.Z`
- node переводится в `drain`
- обновляются `kubelet` и `kubectl`
- рестартуется `kubelet`
- проверяется `Ready`
- выполняется `uncordon`

На остальных control-plane node:

- обновляется `kubeadm`
- выполняется `kubeadm upgrade node`
- дальше те же шаги с `drain`, `kubelet`, `kubectl`, `Ready`, `uncordon`

### Worker

На worker node:

- обновляется `kubeadm`
- выполняется `kubeadm upgrade node`
- node переводится в `drain`
- обновляются `kubelet` и `kubectl`
- рестартуется `kubelet`
- выполняется проверка `Ready`
- node возвращается через `uncordon`

### Jump host

На jump host:

- определяется latest stable release либо версия из `--target`
- переключается или создаётся официальный `pkgs.k8s.io` repo на нужную minor-ветку
- на Debian/Ubuntu при необходимости скачивается `Release.key` и создаётся `/etc/apt/keyrings/kubernetes-apt-keyring.gpg`
- обновляется только `kubectl`
- если передан `--kubeconfig`, дополнительно проверяется подключение к cluster и version skew

---

## Автоматический выбор целевой версии

Если `--target` не передан, скрипт берёт целевую версию из:

```text
https://dl.k8s.io/release/stable.txt
```

Пример проверки вручную:

```bash
curl -fsSL https://dl.k8s.io/release/stable.txt
```

На момент написания README это источник latest stable release line для Kubernetes.

### Источник

- Kubernetes stable release endpoint  
  https://dl.k8s.io/release/stable.txt

---

## Backup и rollback

### Что сохраняется перед upgrade

Во всех случаях:

- metadata для rollback
- backup repo file
- `kubectl version`
- если передан рабочий `kubeconfig`: `kubectl get nodes`, `kubectl get pods -A -o wide`, cluster objects dump
- список Helm releases и repos, если Helm установлен

Дополнительно на control-plane:

- архив `/etc/kubernetes`
- backup `/var/lib/kubelet/config.yaml`, если файл есть
- `etcd` snapshot, если обнаружен stacked etcd

По умолчанию backup складывается в:

```text
/var/backups/k8s-upgrade/<timestamp>-<node-name>
```

### Node-local rollback

Скрипт поддерживает **локальный rollback node**:

- возвращает repo file
- переустанавливает предыдущие версии `kubeadm`, `kubelet`, `kubectl`
- возвращает backup `/etc/kubernetes`
- возвращает backup kubelet config
- рестартует kubelet

Запуск:

```bash
sudo ./k8s-node-upgrade.sh --rollback-from /var/backups/k8s-upgrade/<backup_dir>
```

### Что rollback не делает автоматически

Скрипт **намеренно не делает автоматический cluster-state restore из etcd snapshot**.

Почему так:

- restore etcd — это уже не локальная операция одной node;
- перед restore нужно остановить **все API server instances**;
- нужно восстановить состояние **во всех etcd instances**;
- после этого нужно заново поднять API server instances;
- Kubernetes рекомендует перезапускать и другие control-plane компоненты, чтобы они не работали со stale state.

То есть полноценный etcd restore — это процедура disaster recovery, а не безопасный «быстрый автооткат одной ноды».

### Источники

- Kubernetes: Upgrading kubeadm clusters  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Kubernetes: Operating etcd clusters for Kubernetes  
  https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/

---

## Обновление Helm

Helm обновляется только если явно задано:

```bash
--helm true
```

Пример:

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf \
  --helm true
```

Скрипт использует официальный installer script Helm 4.

### Зачем это отдельный флаг

Helm — это отдельный инструмент, и его обновление лучше держать под контролем отдельно от Kubernetes upgrade.

Причины:

- у Helm свой lifecycle;
- возможны изменения в CLI и plugins;
- не всегда хочется менять Helm на всех node одновременно с cluster upgrade.

### Источник

- Helm Version Support Policy  
  https://helm.sh/docs/topics/version_skew/

---

## Параметры скрипта

```text
--role <auto|control-plane|worker|jump-host>
--first-control-plane <true|false>
--kubeconfig <path>
--target <vX.Y.Z>
--helm <true|false>
--backup-root <dir>
--node-name <name>
--allow-emptydir-loss <true|false>
--dry-run
--rollback-from <backup_dir>
--force-repo-switch
```

### Кратко по важным параметрам

#### `--role`
Роль node. Можно не указывать и оставить `auto`.

#### `--first-control-plane`
`true` только на **первой** control-plane node в текущем minor-шаге.

#### `--kubeconfig`
Путь к kubeconfig, который `kubectl` будет использовать для общения с кластером. Для `jump-host` параметр опционален.

#### `--target`
Явная целевая версия. Если не указана — берётся latest stable.

#### `--helm`
Включает отдельное обновление Helm.

#### `--allow-emptydir-loss`
Добавляет `--delete-emptydir-data` к `kubectl drain`.
По умолчанию выключено, чтобы не потерять ephemeral data без явного согласия.

#### `--dry-run`
Показывает действия без фактического выполнения.

#### `--rollback-from`
Локальный rollback из конкретного backup directory.

#### `--force-repo-switch`
Насильно создаёт/переписывает repo file, если он не найден или не содержит `pkgs.k8s.io`.

---

## Примеры использования

### Посмотреть, что будет сделано

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf \
  --dry-run
```

### Обновить worker до latest stable

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf
```

### Обновить control-plane до конкретной версии

```bash
sudo ./k8s-node-upgrade.sh \
  --role control-plane \
  --first-control-plane true \
  --kubeconfig /etc/kubernetes/admin.conf \
  --target v1.35.3
```

### Выполнить rollback

```bash
sudo ./k8s-node-upgrade.sh \
  --rollback-from /var/backups/k8s-upgrade/20260324T120000Z-node01
```

---

## Как скачать из Git

Ниже шаблоны. Подставь свой URL репозитория.

### Вариант 1: клонировать репозиторий целиком

#### HTTPS

```bash
git clone https://github.com/<org>/<repo>.git
cd <repo>
chmod +x k8s-node-upgrade.sh
chmod +x test_k8s_node_upgrade.sh
```

#### SSH

```bash
git clone git@github.com:<org>/<repo>.git
cd <repo>
chmod +x k8s-node-upgrade.sh
chmod +x test_k8s_node_upgrade.sh
```

### Вариант 2: скачать только скрипт напрямую

Если репозиторий публичный:

```bash
curl -LO https://raw.githubusercontent.com/<org>/<repo>/<branch>/k8s-node-upgrade.sh
chmod +x k8s-node-upgrade.sh
```

И для теста:

```bash
curl -LO https://raw.githubusercontent.com/<org>/<repo>/<branch>/test_k8s_node_upgrade.sh
chmod +x test_k8s_node_upgrade.sh
```

### Вариант 3: скачать конкретный tag/release

```bash
git clone --branch <tag-or-branch> --depth 1 https://github.com/<org>/<repo>.git
cd <repo>
chmod +x k8s-node-upgrade.sh
chmod +x test_k8s_node_upgrade.sh
```

---

## Как запускать тесты

```bash
bash ./test_k8s_node_upgrade.sh
```

Тесты сейчас покрывают:

- version helpers
- логику `drain` args
- auto-detect role
- переключение repo file на новую minor-ветку

---

## Минимальные требования

- Linux
- `bash`
- `systemd`
- `kubectl`
- `kubeadm`
- `kubelet`
- `curl`
- пакетный менеджер: `apt`, `yum`, `dnf` или `dnf5`
- рабочий `kubeconfig`
- выключенный `swap`

Для control-plane со stacked etcd:

- `etcdctl`

---

## Важные эксплуатационные замечания

### 1. Обновляй по порядку

Сначала первая control-plane, потом остальные control-plane, потом worker nodes.

### 2. Не обновляй слишком много worker сразу

Официальная документация рекомендует обновлять worker nodes **по одной** или **по несколько**, но не так, чтобы потерять минимально необходимую capacity для workloads.

### 3. Проверяй CNI отдельно

После upgrade обязательно проверь:

- сетевой plugin
- DNS
- ingress
- storage
- device plugins

### 4. Следи за deprecated APIs

Если в кластере есть старые манифесты или charts с устаревшими API versions, cluster может обновиться, а отдельные workloads — сломаться.

### 5. Для 1.35 скрипт проверяет cgroups v2

В скрипте заложена preflight-проверка для target `1.35`, чтобы не идти в upgrade на node с неподходящей cgroup-конфигурацией.

---

## Источники

Только official / upstream документы:

1. Kubernetes — Upgrading kubeadm clusters  
   https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
2. Kubernetes — Upgrading Linux nodes  
   https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
3. Kubernetes — Changing the Kubernetes package repository  
   https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/
4. Kubernetes — kubectl drain  
   https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/
5. Kubernetes — Organizing Cluster Access Using kubeconfig Files  
   https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
6. Kubernetes — Troubleshooting kubectl  
   https://kubernetes.io/docs/tasks/debug/debug-cluster/troubleshoot-kubectl/
7. Kubernetes — Operating etcd clusters for Kubernetes  
   https://kubernetes.io/docs/tasks/administer-cluster/configure-upgrade-etcd/
8. Kubernetes stable release endpoint  
   https://dl.k8s.io/release/stable.txt
9. Helm — Version Support Policy  
   https://helm.sh/docs/topics/version_skew/

