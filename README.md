# k8s-node-upgrade.sh

Скрипт для пошагового обновления Kubernetes в `kubeadm`-кластере и отдельного обновления `kubectl` на jump host.

Поддерживаемые режимы:
- `control-plane`
- `worker`
- `jump-host`
- `auto` — пытается определить роль автоматически

Скрипт рассчитан на Linux с `apt`, `yum`, `dnf` или `dnf5`.

---

## Что делает скрипт

### Для `control-plane`
- делает preflight-проверки;
- создаёт локальные backup'ы;
- переключает `pkgs.k8s.io` repo на нужную minor-ветку;
- обновляет `kubeadm`;
- выполняет `kubeadm upgrade apply` на первой control-plane node и `kubeadm upgrade node` на остальных;
- делает `drain` node;
- обновляет `kubelet` и `kubectl`;
- перезапускает `kubelet`;
- ждёт `Ready` и делает `uncordon`.

### Для `worker`
- делает preflight-проверки;
- создаёт локальные backup'ы;
- переключает `pkgs.k8s.io` repo на нужную minor-ветку;
- обновляет `kubeadm`;
- выполняет `kubeadm upgrade node`;
- делает `drain` node;
- обновляет `kubelet` и `kubectl`;
- перезапускает `kubelet`;
- ждёт `Ready` и делает `uncordon`.

### Для `jump-host`
- обновляет **только** `kubectl`;
- не делает `drain`;
- не трогает `kubeadm`, `kubelet`, `etcd`, `/etc/kubernetes`;
- при наличии `--kubeconfig` дополнительно проверяет подключение к кластеру и не даёт обновить `kubectl` на неподдерживаемую minor-версию относительно `kube-apiserver`.

---

## Что именно обновляется

### В режимах `control-plane` и `worker`
- `kubeadm`
- `kubelet`
- `kubectl`
- repo file Kubernetes packages (`pkgs.k8s.io`)
- локальная node-конфигурация через `kubeadm upgrade`

### В режиме `jump-host`
- только `kubectl`
- при `--helm true` — ещё и Helm

---

## Что скрипт не обновляет

Скрипт специально **не** обновляет автоматически:
- CNI
- CSI
- ingress-controller
- operators
- device plugins
- container runtime
- ОС и kernel
- ваши workload'ы
- Helm charts и values
- manifest'ы с deprecated API versions

Это нужно обновлять отдельно по документации конкретного компонента.

---

## Почему обновление идёт по каждой minor-версии

Потому что для `kubeadm` **нельзя перескакивать через minor-версии**.

Официальная документация Kubernetes прямо говорит:

> `Skipping MINOR versions when upgrading is unsupported.`

Кроме того, для `pkgs.k8s.io` используется **отдельный репозиторий на каждую minor-ветку**, и при переходе между minor-версиями repo тоже нужно переключать.

Именно поэтому скрипт строит цепочку такого вида:

```text
1.31.x -> 1.32.latest -> 1.33.latest -> 1.34.latest -> 1.35.latest
```

а не пытается делать скачок:

```text
1.31 -> 1.35
```

### Источники
- Upgrading kubeadm clusters  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/kubeadm-upgrade/
- Changing The Kubernetes Package Repository  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/change-package-repository/

---

## Зачем нужен kubeconfig на worker

На `worker` скрипт выполняет не только локальные действия в ОС, но и команды через Kubernetes API:
- `kubectl get node`
- `kubectl drain <node>`
- `kubectl wait --for=condition=Ready node/...`
- `kubectl uncordon <node>`

Эти команды работают через `kube-apiserver`, а не напрямую с локальной машиной.

Поэтому на `worker` нужен `kubeconfig`, в котором есть:
- адрес API server;
- CA;
- credentials;
- права на `get`, `drain`, `uncordon`, `wait`.

Без `kubeconfig` можно локально обновить пакет `kubectl`, но нельзя безопасно вывести node из эксплуатации и вернуть её обратно.

### Источники
- Upgrading Linux nodes  
  https://kubernetes.io/docs/tasks/administer-cluster/kubeadm/upgrading-linux-nodes/
- kubectl drain  
  https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/
- Organizing Cluster Access Using kubeconfig Files  
  https://kubernetes.io/docs/concepts/configuration/organize-cluster-access-kubeconfig/

---

## Jump host: важное ограничение по версии kubectl

Для `jump-host` скрипт обновляет только `kubectl`. Но `kubectl` не должен быть слишком далеко по minor-версии от `kube-apiserver`.

Официальное правило такое:

> `kubectl` is supported within one minor version (older or newer) of `kube-apiserver`.

Поэтому, если запускать режим `jump-host` с `--kubeconfig`, скрипт дополнительно проверяет version skew и останавливается, если целевая версия `kubectl` выходит за допустимый диапазон.

Это сделано специально, чтобы не обновить jump host до версии клиента, которая уже не поддерживается твоим control plane.

### Источники
- Install and Set Up kubectl on Linux  
  https://kubernetes.io/docs/tasks/tools/install-kubectl-linux/
- Version Skew Policy  
  https://kubernetes.io/releases/version-skew-policy/

---

## Backup'и

Перед изменениями скрипт создаёт каталог backup, по умолчанию:

```bash
/var/backups/k8s-upgrade/<timestamp>-<node>
```

Туда попадает:
- metadata о версии и параметрах запуска;
- backup repo file;
- `kubectl` client version;
- cluster views через `kubectl`, если есть `kubeconfig`;
- список Helm releases и repo, если Helm установлен;
- на `control-plane`: архив `/etc/kubernetes` и `kubelet` config;
- на `control-plane` со `stacked etcd`: snapshot `etcd`.

### Важный момент по `etcd`

В текущей версии скрипта для snapshot `stacked etcd` требуется **`etcdctl` на host**.

Если на control-plane нет `etcdctl` в `PATH`, скрипт остановится с ошибкой:

```text
ERROR: Не найдена команда: etcdctl
```

В таком случае нужно либо:
- установить `etcdctl` на host;
- либо доработать скрипт под работу через `etcd` static pod.

---

## Откат

Есть только **node-local rollback**:
- откат repo file;
- откат пакетов `kubeadm`, `kubelet`, `kubectl`, если их предыдущие версии сохранены в metadata;
- восстановление `/etc/kubernetes` и `kubelet` config, если они были сохранены.

Запуск:

```bash
sudo ./k8s-node-upgrade.sh --rollback-from /var/backups/k8s-upgrade/<backup_dir>
```

### Что rollback не делает

Скрипт **не** делает автоматический cluster-wide restore `etcd`.

Это сделано намеренно: полный restore `etcd` — отдельная процедура disaster recovery, её нельзя безопасно автоматизировать как "просто откат одной node".

---

## Работа с `emptyDir` и local ephemeral storage

Во время `drain` Kubernetes может остановить процесс, если на node есть Pod'ы с local storage / `emptyDir`.

Типичная ошибка выглядит так:

```text
cannot delete Pods with local storage (use --delete-emptydir-data to override)
```

По умолчанию скрипт **не** добавляет `--delete-emptydir-data`, чтобы не потерять временные данные автоматически.

Если ты понимаешь, что потеря `emptyDir` допустима, запускай так:

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf \
  --allow-emptydir-loss true
```

Этот флаг добавляет к `drain`:

```bash
--delete-emptydir-data
```

### Когда это можно включать
- cache
- temp files
- scratch space
- промежуточные данные, которые допустимо потерять

### Когда нельзя включать вслепую
Если приложение складывает в `emptyDir` важное runtime-состояние, оно пропадёт после eviction pod'а.

### Источники
- kubectl drain  
  https://kubernetes.io/docs/reference/kubectl/generated/kubectl_drain/
- Volumes / emptyDir  
  https://kubernetes.io/docs/concepts/storage/volumes/

---

## Как скачать из Git

### Вариант 1: clone репозитория

```bash
git clone <repo-url>
cd <repo-dir>
chmod +x k8s-node-upgrade.sh
```

### Вариант 2: скачать только файл скрипта из raw URL

```bash
curl -fsSL -o k8s-node-upgrade.sh <raw-url-to-k8s-node-upgrade.sh>
chmod +x k8s-node-upgrade.sh
```

### Вариант 3: скачать и README

```bash
curl -fsSL -o k8s-node-upgrade.sh <raw-url-to-k8s-node-upgrade.sh>
curl -fsSL -o README.md <raw-url-to-README.md>
chmod +x k8s-node-upgrade.sh
```

Если у тебя приватный GitLab/GitHub, вместо `<repo-url>` и `<raw-url-...>` подставь реальные адреса своего репозитория.

---

## Примеры запуска

### Первая control-plane node

```bash
sudo ./k8s-node-upgrade.sh \
  --role control-plane \
  --first-control-plane true \
  --kubeconfig /etc/kubernetes/admin.conf
```

### Остальные control-plane nodes

```bash
sudo ./k8s-node-upgrade.sh \
  --role control-plane \
  --first-control-plane false \
  --kubeconfig /etc/kubernetes/admin.conf
```

### Worker node

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf
```

### Worker node с разрешением удалить `emptyDir`

```bash
sudo ./k8s-node-upgrade.sh \
  --role worker \
  --kubeconfig /root/.kube/admin.conf \
  --allow-emptydir-loss true
```

### Jump host без доступа к кластеру

```bash
sudo ./k8s-node-upgrade.sh --role jump-host
```

### Jump host с проверкой совместимости через kubeconfig

```bash
sudo ./k8s-node-upgrade.sh \
  --role jump-host \
  --kubeconfig /root/.kube/admin.conf
```

### Любой режим + Helm

```bash
sudo ./k8s-node-upgrade.sh --role jump-host --helm true
```

или

```bash
sudo ./k8s-node-upgrade.sh --role worker --kubeconfig /root/.kube/admin.conf --helm true
```

---

## Как работает `--role auto`

Скрипт пытается определить роль так:
- если найден `/etc/kubernetes/manifests/kube-apiserver.yaml` → `control-plane`;
- если есть `kubelet` или следы его конфигурации → `worker`;
- иначе → `jump-host`.

Если не хочешь полагаться на auto-detection, лучше указывать `--role` явно.

---

## Полезные замечания

1. Сначала обновляется первая `control-plane` node.
2. Потом остальные `control-plane` nodes.
3. Потом `worker` nodes.
4. `jump-host` имеет смысл обновлять после того, как control plane уже приблизился к целевой версии, чтобы не нарушить supported skew для `kubectl`.
5. После cluster upgrade отдельно проверь CNI, ingress, operators, monitoring stack и свои приложения.

---

## Короткий summary

- `control-plane` и `worker` режимы обновляют Kubernetes node полностью.
- `jump-host` обновляет только `kubectl`.
- На `worker` нужен `kubeconfig`, потому что `drain/uncordon/wait` идут через API server.
- Через minor-версии перепрыгивать нельзя.
- Для `jump-host` лучше передавать `--kubeconfig`, чтобы скрипт проверил supported version skew.
- Для `stacked etcd` в текущей версии скрипта нужен `etcdctl` на host.
