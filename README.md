# k8s-node-upgrade.sh

Безопасный пошаговый upgrade `kubeadm`-кластера Kubernetes на Linux node.

Скрипт запускается **локально на каждой node**: на `control-plane` и на `worker`. Он делает preflight-проверки, создаёт backup, обновляет Kubernetes **по одной minor-версии за шаг**, умеет обновлять `kubeadm`, `kubelet`, `kubectl`, переключать `pkgs.k8s.io` repo на нужную minor-ветку и, при желании, отдельно обновлять Helm.

> Скрипт рассчитан на `kubeadm + Linux + systemd + apt/yum/dnf/dnf5`.

---

## Что делает скрипт

На каждой node скрипт:

1. Определяет роль node: `control-plane` или `worker`.
2. Проверяет доступ к кластеру через `kubectl` и `kubeconfig`.
3. Определяет текущую локальную версию `kubelet`.
4. Получает целевую версию:
   - либо из `--target vX.Y.Z`
   - либо автоматически из `https://dl.k8s.io/release/stable.txt`
5. Если требуется minor-upgrade, **идёт последовательно по всем промежуточным minor-версиям**.
6. До начала upgrade делает preflight-проверки, в том числе проверяет, что `drain` не упрётся в очевидные блокеры.
7. Перед обновлением создаёт локальные backup'ы:
   - состояние node и cluster view через `kubectl`
   - текущий repo file
   - на `control-plane`: `/etc/kubernetes`, `kubelet` config
   - на `control-plane` со `stacked etcd`: `etcd` snapshot
8. Для каждого upgrade-step:
   - переключает пакетный репозиторий на нужную minor-ветку `pkgs.k8s.io`
   - обновляет `kubeadm`
   - выполняет `kubeadm upgrade apply` или `kubeadm upgrade node`
   - делает `drain` node
   - обновляет `kubelet` и `kubectl`
   - перезапускает `kubelet`
   - ждёт `Ready`
   - делает `uncordon`
9. Если указан `--helm true`, отдельно обновляет Helm через официальный installer script.

---

## Что именно обновляется

Скрипт обновляет:

- `kubeadm`
- `kubelet`
- `kubectl`
- `pkgs.k8s.io` repo file на нужную minor-ветку
- `control-plane` компоненты через `kubeadm upgrade apply`
- `worker` node конфигурацию через `kubeadm upgrade node`
- Helm, если задан `--helm true`

---

## Что скрипт не обновляет

Это сделано специально, чтобы не автоматизировать то, где у разных кластеров слишком много vendor-specific отличий.

Скрипт **не** обновляет автоматически:

- CNI plugin
- CSI drivers
- device plugins
- ingress-controller
- сторонние operators
- container runtime
- ОС и kernel
- ваши приложения, Helm charts и их values
- манифесты с deprecated API versions

После cluster upgrade это нужно проверять отдельно по документации конкретного компонента.

---

## Почему upgrade идёт по каждой minor-версии

Потому что для `kubeadm` **перескакивать через minor-версии нельзя**.

Официальная документация Kubernetes прямо говорит:

> `Skipping MINOR versions when upgrading is unsupported.`

Практический смысл такой:

- уменьшается риск несовместимости конфигов и API;
- соблюдается `version skew policy`;
- `kubeadm` ожидает поддерживаемую последовательность переходов;
- на `pkgs.k8s.io` пакеты разложены по **отдельным minor-репозиториям**, поэтому при каждом minor-upgrade нужно переключать repo.

Именно поэтому скрипт не пытается делать прыжок вида:

```text
1.31 -> 1.35
```

А строит цепочку шагов:

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

### Источники

- Kubernetes: Upgrading Linux nodes  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
- Kubernetes: kubectl drain  
  https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/
- Kubernetes: Organizing Cluster Access Using kubeconfig Files  
  https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/

---

## Какой kubeconfig использовать на worker

### Самый простой вариант

Временно положить на worker `root-only` kubeconfig, который точно имеет нужные права.

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

Официальная документация Kubernetes отдельно предупреждает: использовать нужно только `kubeconfig` из доверенных источников.

---

## Новое поведение drain: precheck и защита от потери данных

Перед началом upgrade скрипт делает **предварительную проверку** `drain` через `kubectl drain --dry-run=server`.

Это нужно, чтобы заранее остановиться, если node нельзя безопасно освободить.

Сейчас скрипт специально проверяет как минимум два типовых блокера:

1. **Pods с local ephemeral storage / emptyDir**
2. **PodDisruptionBudget**, который не позволяет эвиктить pod'ы

### Если на node есть Pod'ы с emptyDir

По умолчанию сценарий **останавливается**, чтобы не потерять данные из `emptyDir`.

В логах это выглядит примерно так:

```text
cannot delete Pods with local storage (use --delete-emptydir-data to override)
```

Это штатное поведение `kubectl drain`.

### Что делать в этом случае

Если для этих pod'ов **допустима потеря временных данных**, можно явно разрешить такой drain:

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf \
  --allow-emptydir-loss true
```

Этот флаг добавляет к `drain` параметр:

```bash
--delete-emptydir-data
```

### Когда включать `--allow-emptydir-loss true`

Только если ты понимаешь, что `emptyDir` в этих pod'ах используется как:

- cache
- temp storage
- scratch space
- промежуточные файлы, которые допустимо потерять

### Когда не включать

Не включай этот флаг вслепую, если приложение хранит в `emptyDir` важное runtime-состояние, которое после eviction пропадёт.

### Источники

- Kubernetes: kubectl drain  
  https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/
- Kubernetes: Volumes / emptyDir  
  https://kubernetes.io/docs/concepts/storage/volumes/

---

## Что будет, если drain блокируется PodDisruptionBudget

Если `drain` нельзя выполнить из-за `PDB`, скрипт останавливается ещё на precheck.

В этом случае нужно сначала:

- увеличить количество реплик;
- временно изменить `PodDisruptionBudget`;
- убедиться, что workload может безопасно пережить eviction.

---

## Что делать, если предыдущий запуск упал во время drain

Если использовалась **старая версия скрипта** или ошибка произошла уже после начала реального `drain`, node может остаться в состоянии `SchedulingDisabled`.

Тогда её нужно вернуть вручную:

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon <node-name>
```

Пример:

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf uncordon deb13-jh-k8s-worker-2
```

Перед повторным запуском проверь:

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes
```

---

## Требования и ограничения

### Control-plane

Для `control-plane` скрипту нужны:

- `kubeadm`
- `kubelet`
- `kubectl`
- `curl`
- доступный `kubeconfig`
- для `stacked etcd`: установленный на host `etcdctl`

Если на `control-plane` используется локальный `stacked etcd`, скрипт делает snapshot через `etcdctl` на host.

Если `etcdctl` не установлен, сценарий остановится с ошибкой:

```text
ERROR: Не найдена команда: etcdctl
```

В таком случае перед запуском нужно либо установить `etcdctl`, либо доработать сценарий под использование `etcdctl` из static pod.

### Worker

Для `worker` нужны:

- `kubeadm`
- `kubelet`
- `kubectl`
- `curl`
- `kubeconfig` с правами на `get/drain/wait/uncordon`

---

## Порядок upgrade по ролям

Официальный порядок такой:

1. Первая `control-plane` node
2. Остальные `control-plane` nodes
3. `worker` nodes

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

### Worker с разрешением потери `emptyDir`

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf \
  --allow-emptydir-loss true
```

### С отдельным обновлением Helm

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf \
  --helm true
```

---

## Как работает upgrade внутри скрипта

### Control-plane

На первой `control-plane` node:

- обновляется `kubeadm`
- выполняется `kubeadm upgrade plan`
- выполняется `kubeadm upgrade apply vX.Y.Z`
- node переводится в `drain`
- обновляются `kubelet` и `kubectl`
- рестартуется `kubelet`
- проверяется `Ready`
- выполняется `uncordon`

На остальных `control-plane` node:

- обновляется `kubeadm`
- выполняется `kubeadm upgrade node`
- дальше те же шаги с `drain`, `kubelet`, `kubectl`, `Ready`, `uncordon`

### Worker

На `worker` node:

- обновляется `kubeadm`
- выполняется `kubeadm upgrade node`
- node переводится в `drain`
- обновляются `kubelet` и `kubectl`
- рестартуется `kubelet`
- выполняется проверка `Ready`
- node возвращается через `uncordon`

---

## Backup и rollback

### Что сохраняется

В каталог backup'а сохраняются:

- `kubectl version`
- список node
- список pod'ов
- cluster objects (`ds`, `deploy`, `sts`, `svc`, `ing`, `job`, `cronjob`, `pvc`, `pv`)
- Helm releases и repos, если Helm установлен
- repo file
- `/etc/kubernetes` на `control-plane`
- `kubelet` config
- `etcd` snapshot на `stacked etcd`
- `metadata.env` для node-local rollback

### Где лежат backup'ы

По умолчанию:

```text
/var/backups/k8s-upgrade
```

### Откат

Скрипт поддерживает **node-local rollback** из backup directory:

```bash
sudo ./k8s-node-upgrade.sh --rollback-from /var/backups/k8s-upgrade/<backup_dir>
```

Важно: это **не полный cluster-wide restore** и не автоматическое восстановление всего control-plane state. Полное восстановление etcd и cluster state нужно делать отдельно по процедуре Kubernetes.

---

## Параметры

```text
--role <auto|control-plane|worker>
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

---

## Как скачать из Git

### Вариант 1. Склонировать весь репозиторий

```bash
git clone <repo-url>
cd <repo-dir>
chmod +x k8s-node-upgrade.sh
```

Пример:

```bash
git clone https://github.com/your-org/k8s-node-upgrade.git
cd k8s-node-upgrade
chmod +x k8s-node-upgrade.sh
```

### Вариант 2. Скачать один файл напрямую

Если в репозитории есть raw URL:

```bash
curl -fsSL -o k8s-node-upgrade.sh <raw-url>
chmod +x k8s-node-upgrade.sh
```

Пример:

```bash
curl -fsSL -o k8s-node-upgrade.sh https://raw.githubusercontent.com/your-org/k8s-node-upgrade/main/k8s-node-upgrade.sh
chmod +x k8s-node-upgrade.sh
```

### Вариант 3. Скачать README отдельно

```bash
curl -fsSL -o README.md <raw-readme-url>
```

---

## Как пользоваться после скачивания

### 1. Проверить доступы

Убедись, что на node есть:

- `root`/`sudo`
- корректный `kubeconfig`
- доступ к пакетному репозиторию Kubernetes
- установленный `kubectl`

### 2. Сделать файл исполняемым

```bash
chmod +x ./k8s-node-upgrade.sh
```

### 3. Запускать по правильному порядку

Сначала первая `control-plane`, потом остальные `control-plane`, потом `worker`.

### 4. После каждого шага проверить состояние

```bash
kubectl --kubeconfig /etc/kubernetes/admin.conf get nodes -o wide
kubectl --kubeconfig /etc/kubernetes/admin.conf get pods -A -o wide
```

---

## Helm

Если указан флаг:

```bash
--helm true
```

скрипт отдельно обновит Helm через официальный installer script Helm.

В текущей реализации используется installer для Helm 4.

Перед включением этого флага проверь, что:

- твои automation/jobs совместимы с Helm 4;
- плагины, если они используются, тоже совместимы.

Источник:

- Helm install docs  
  https://helm.sh/docs/intro/install/

---

## Рекомендации по безопасному использованию

1. Сначала прогоняй upgrade на тестовом кластере.
2. Не включай `--allow-emptydir-loss true`, пока не понял, что именно лежит в `emptyDir`.
3. Перед `control-plane` upgrade отдельно проверь стратегию восстановления `etcd`.
4. Не пытайся обновить сразу все node параллельно.
5. После каждой node проверяй `Ready`, `pods`, critical workloads и monitoring.

---

## Основные официальные источники

- Kubernetes: Upgrading kubeadm clusters  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Kubernetes: Upgrading Linux nodes  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
- Kubernetes: Change the package repository  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/
- Kubernetes: kubectl drain  
  https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/
- Kubernetes: kubeconfig  
  https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/
- Kubernetes: Volumes / emptyDir  
  https://kubernetes.io/docs/concepts/storage/volumes/
- Helm install docs  
  https://helm.sh/docs/intro/install/
- Kubernetes stable release pointer  
  https://dl.k8s.io/release/stable.txt
