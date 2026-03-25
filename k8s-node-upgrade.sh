#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_NAME=$(basename "$0")
VERSION="1.1.0"

ROLE="auto"                    # auto|control-plane|worker|jump-host
FIRST_CONTROL_PLANE="false"   # true only for the first CP node in each minor step
UPDATE_HELM="false"           # true|false
DRY_RUN="false"
ALLOW_EMPTYDIR_LOSS="false"
BACKUP_ROOT="/var/backups/k8s-upgrade"
TARGET_VERSION=""
KUBECONFIG_PATH="${KUBECONFIG:-}"
NODE_NAME=""
ROLLBACK_FROM=""
FORCE_REPO_SWITCH="false"

CURRENT_STEP_VERSION=""
PKG_FAMILY=""
PKG_REPO_FILE=""
BACKUP_DIR=""
CONTROL_PLANE="false"

log()  { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*"; }
warn() { printf '[%s] WARN: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date -u +%FT%TZ)" "$*" >&2; exit 1; }

usage() {
  cat <<USAGE
$SCRIPT_NAME v$VERSION

Безопасное пошаговое обновление kubeadm-кластера Kubernetes на Linux node,
а также отдельный режим jump host с обновлением только kubectl.

Примеры:
  sudo $SCRIPT_NAME --role control-plane --first-control-plane true --kubeconfig /etc/kubernetes/admin.conf
  sudo $SCRIPT_NAME --role control-plane --first-control-plane false --kubeconfig /etc/kubernetes/admin.conf
  sudo $SCRIPT_NAME --role worker --kubeconfig /root/.kube/admin.conf
  sudo $SCRIPT_NAME --role jump-host
  sudo $SCRIPT_NAME --role jump-host --kubeconfig /root/.kube/admin.conf
  sudo $SCRIPT_NAME --role worker --kubeconfig /root/.kube/admin.conf --helm true
  sudo $SCRIPT_NAME --rollback-from /var/backups/k8s-upgrade/20260324T120000Z-node01

Параметры:
  --role <auto|control-plane|worker|jump-host>
  --first-control-plane <true|false>   Нужен только для control-plane; true только на первой CP node в minor-шаге
  --kubeconfig <path>                  Для control-plane/worker обязателен. Для jump-host опционален и нужен только для проверки связи/совместимости с кластером
  --target <vX.Y.Z>                    Целевая версия; по умолчанию последняя стабильная из dl.k8s.io/release/stable.txt
  --helm <true|false>                  Отдельно обновить Helm после Kubernetes; по умолчанию false
  --backup-root <dir>                  Корневой каталог для backup'ов; по умолчанию /var/backups/k8s-upgrade
  --node-name <name>                   Имя Node в Kubernetes; по умолчанию hostname -> hostname -s -> hostname -f
  --allow-emptydir-loss <true|false>   Добавляет --delete-emptydir-data при drain; по умолчанию false
  --dry-run                            Только показать действия
  --rollback-from <backup_dir>         Откат node-local файлов и пакетов из указанного backup
  --force-repo-switch                  Насильно переписать repo file даже если не найден pkgs.k8s.io
  -h, --help
USAGE
}

cleanup_on_error() {
  local rc=$?
  warn "Сценарий завершился с ошибкой (exit=${rc})."
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    warn "Локальные backup'ы находятся в: $BACKUP_DIR"
    warn "Для node-local отката используйте: sudo $SCRIPT_NAME --rollback-from $BACKUP_DIR"
  fi
  exit "$rc"
}
trap cleanup_on_error ERR

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    printf '[DRY-RUN] %s\n' "$*"
  else
    eval "$@"
  fi
}

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Запускай от root (или через sudo)."
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "Не найдена команда: $c"
  done
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --role) ROLE="$2"; shift 2 ;;
      --first-control-plane) FIRST_CONTROL_PLANE="$2"; shift 2 ;;
      --kubeconfig) KUBECONFIG_PATH="$2"; shift 2 ;;
      --target) TARGET_VERSION="$2"; shift 2 ;;
      --helm) UPDATE_HELM="$2"; shift 2 ;;
      --backup-root) BACKUP_ROOT="$2"; shift 2 ;;
      --node-name) NODE_NAME="$2"; shift 2 ;;
      --allow-emptydir-loss) ALLOW_EMPTYDIR_LOSS="$2"; shift 2 ;;
      --dry-run) DRY_RUN="true"; shift ;;
      --rollback-from) ROLLBACK_FROM="$2"; shift 2 ;;
      --force-repo-switch) FORCE_REPO_SWITCH="true"; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "Неизвестный параметр: $1" ;;
    esac
  done

  case "$ROLE" in auto|control-plane|worker|jump-host) ;; *) die "--role должен быть auto|control-plane|worker|jump-host" ;; esac
  case "$FIRST_CONTROL_PLANE" in true|false) ;; *) die "--first-control-plane должен быть true|false" ;; esac
  case "$UPDATE_HELM" in true|false) ;; *) die "--helm должен быть true|false" ;; esac
  case "$ALLOW_EMPTYDIR_LOSS" in true|false) ;; *) die "--allow-emptydir-loss должен быть true|false" ;; esac
}

normalize_version() {
  local v="$1"
  v="${v#v}"
  printf '%s' "$v"
}

version_lt() {
  [[ "$(printf '%s\n%s\n' "$(normalize_version "$1")" "$(normalize_version "$2")" | sort -V | head -n1)" != "$(normalize_version "$2")" ]]
}

version_eq() {
  [[ "$(normalize_version "$1")" == "$(normalize_version "$2")" ]]
}

version_major_minor() {
  local v
  v=$(normalize_version "$1")
  awk -F. '{print $1"."$2}' <<<"$v"
}

version_patch() {
  local v
  v=$(normalize_version "$1")
  awk -F. '{print $3}' <<<"$v"
}

bump_minor() {
  local v major minor
  v=$(normalize_version "$1")
  major=$(awk -F. '{print $1}' <<<"$v")
  minor=$(awk -F. '{print $2}' <<<"$v")
  printf '%s.%s' "$major" "$((minor + 1))"
}

detect_pkg_family() {
  if command -v apt-get >/dev/null 2>&1; then
    PKG_FAMILY="apt"
    PKG_REPO_FILE="/etc/apt/sources.list.d/kubernetes.list"
  elif command -v dnf5 >/dev/null 2>&1; then
    PKG_FAMILY="dnf5"
    PKG_REPO_FILE="/etc/yum.repos.d/kubernetes.repo"
  elif command -v dnf >/dev/null 2>&1; then
    PKG_FAMILY="dnf"
    PKG_REPO_FILE="/etc/yum.repos.d/kubernetes.repo"
  elif command -v yum >/dev/null 2>&1; then
    PKG_FAMILY="yum"
    PKG_REPO_FILE="/etc/yum.repos.d/kubernetes.repo"
  else
    die "Поддерживаются только apt / yum / dnf / dnf5."
  fi
}

set_default_kubeconfig() {
  if [[ -z "$KUBECONFIG_PATH" && -f /etc/kubernetes/admin.conf ]]; then
    KUBECONFIG_PATH="/etc/kubernetes/admin.conf"
  fi
}

detect_role() {
  if [[ "$ROLE" == "auto" ]]; then
    if [[ -f /etc/kubernetes/manifests/kube-apiserver.yaml ]]; then
      ROLE="control-plane"
    elif command -v kubelet >/dev/null 2>&1 || [[ -f /var/lib/kubelet/config.yaml ]] || [[ -d /var/lib/kubelet ]]; then
      ROLE="worker"
    else
      ROLE="jump-host"
    fi
  fi

  if [[ "$ROLE" == "control-plane" ]]; then
    CONTROL_PLANE="true"
  else
    CONTROL_PLANE="false"
    FIRST_CONTROL_PLANE="false"
  fi
}

resolve_node_name() {
  if [[ -n "$NODE_NAME" ]]; then
    return
  fi

  NODE_NAME=$(hostname 2>/dev/null || true)
  if [[ -n "$NODE_NAME" && -n "$KUBECONFIG_PATH" && -f "$KUBECONFIG_PATH" ]]; then
    if kubectl --kubeconfig "$KUBECONFIG_PATH" get node "$NODE_NAME" >/dev/null 2>&1; then
      return
    fi
  fi

  NODE_NAME=$(hostname -s 2>/dev/null || true)
  if [[ -n "$NODE_NAME" && -n "$KUBECONFIG_PATH" && -f "$KUBECONFIG_PATH" ]]; then
    if kubectl --kubeconfig "$KUBECONFIG_PATH" get node "$NODE_NAME" >/dev/null 2>&1; then
      return
    fi
  fi

  NODE_NAME=$(hostname -f 2>/dev/null || true)
  [[ -n "$NODE_NAME" ]] || die "Не удалось определить node name. Передай его явно через --node-name."
}

current_local_kubelet_version() {
  kubelet --version | awk '{print $2}' | sed 's/^v//'
}

current_local_kubectl_version() {
  kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion:/ {print $2; exit}' | sed 's/^v//'
}


fetch_latest_stable() {
  curl -fsSL https://dl.k8s.io/release/stable.txt | sed 's/^v//'
}

preflight_common() {
  require_root
  require_cmd bash sed awk grep sort cut date mkdir cp tar curl
  detect_pkg_family
  set_default_kubeconfig
  detect_role

  if [[ -z "$TARGET_VERSION" ]]; then
    TARGET_VERSION=$(fetch_latest_stable)
  fi
  TARGET_VERSION=$(normalize_version "$TARGET_VERSION")

  if [[ "$ROLE" == "jump-host" ]]; then
    require_cmd kubectl
    if [[ -z "$NODE_NAME" ]]; then
      NODE_NAME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo jump-host)
    fi
    if [[ -n "$KUBECONFIG_PATH" ]]; then
      [[ -f "$KUBECONFIG_PATH" ]] || die "Указанный kubeconfig не найден: $KUBECONFIG_PATH"
      kubectl --kubeconfig "$KUBECONFIG_PATH" version >/dev/null 2>&1 || die "kubectl не может подключиться к кластеру через $KUBECONFIG_PATH"
    fi
    return
  fi

  require_cmd systemctl kubeadm kubelet kubectl
  [[ -n "$KUBECONFIG_PATH" && -f "$KUBECONFIG_PATH" ]] || die "Нужен kubeconfig с правами drain/uncordon/get. Передай --kubeconfig <path>."
  resolve_node_name

  if swapon --show | grep -q .; then
    die "Swap должен быть выключен перед upgrade Kubernetes."
  fi

  kubectl --kubeconfig "$KUBECONFIG_PATH" version >/dev/null 2>&1 || die "kubectl не может подключиться к кластеру через $KUBECONFIG_PATH"
  kubectl --kubeconfig "$KUBECONFIG_PATH" get node "$NODE_NAME" >/dev/null 2>&1 || die "Node '$NODE_NAME' не найдена в кластере. Укажи правильное имя через --node-name."

  local cur
  cur=$(current_local_kubelet_version)
  if [[ "$(version_major_minor "$TARGET_VERSION")" == "1.35" ]]; then
    if [[ "$(stat -fc %T /sys/fs/cgroup 2>/dev/null || true)" != "cgroup2fs" ]]; then
      die "Целевой релиз 1.35 ожидает cgroups v2 на Linux nodes. На этой node обнаружен не cgroup2fs."
    fi
  fi

  if [[ "$CONTROL_PLANE" == "true" && "$FIRST_CONTROL_PLANE" == "true" && ! -f /etc/kubernetes/admin.conf ]]; then
    die "Для первой control-plane node нужен /etc/kubernetes/admin.conf."
  fi
}

prepare_backup_dir() {
  BACKUP_DIR="${BACKUP_ROOT%/}/$(date -u +%Y%m%dT%H%M%SZ)-${NODE_NAME}"
  run "mkdir -p '$BACKUP_DIR'"
}

metadata_file() {
  printf '%s/metadata.env' "$BACKUP_DIR"
}

save_metadata() {
  local prev_kubeadm="" prev_kubelet="" prev_kubectl=""
  if command -v kubeadm >/dev/null 2>&1; then
    prev_kubeadm=$(kubeadm version -o short 2>/dev/null | sed 's/^v//')
  fi
  if [[ "$ROLE" != "jump-host" ]] && command -v kubelet >/dev/null 2>&1; then
    prev_kubelet=$(current_local_kubelet_version)
  fi
  if command -v kubectl >/dev/null 2>&1; then
    prev_kubectl=$(current_local_kubectl_version)
  fi

  cat > "$(metadata_file)" <<META
ROLE=$ROLE
FIRST_CONTROL_PLANE=$FIRST_CONTROL_PLANE
NODE_NAME=$NODE_NAME
KUBECONFIG_PATH=$KUBECONFIG_PATH
PKG_FAMILY=$PKG_FAMILY
PKG_REPO_FILE=$PKG_REPO_FILE
PREV_KUBEADM=$prev_kubeadm
PREV_KUBELET=$prev_kubelet
PREV_KUBECTL=$prev_kubectl
BACKUP_DIR=$BACKUP_DIR
META
}

backup_repo_file() {
  if [[ -f "$PKG_REPO_FILE" ]]; then
    run "cp -a '$PKG_REPO_FILE' '$BACKUP_DIR/$(basename "$PKG_REPO_FILE").bak'"
  else
    warn "Файл repo не найден: $PKG_REPO_FILE"
  fi
}

backup_cluster_views() {
  run "kubectl version --client -o yaml > '$BACKUP_DIR/kubectl-client-version.yaml'"
  if [[ -z "$KUBECONFIG_PATH" || ! -f "$KUBECONFIG_PATH" ]]; then
    warn "kubeconfig не передан: пропускаю backup cluster view через kubectl."
  else
    run "kubectl --kubeconfig '$KUBECONFIG_PATH' version -o yaml > '$BACKUP_DIR/kubectl-version.yaml'"
    run "kubectl --kubeconfig '$KUBECONFIG_PATH' get nodes -o wide > '$BACKUP_DIR/nodes.txt'"
    run "kubectl --kubeconfig '$KUBECONFIG_PATH' get pods -A -o wide > '$BACKUP_DIR/pods-wide.txt'"
    run "kubectl --kubeconfig '$KUBECONFIG_PATH' get ds,deploy,sts,svc,ing,job,cronjob,pvc,pv -A -o yaml > '$BACKUP_DIR/cluster-objects.yaml'"
  fi
  if command -v helm >/dev/null 2>&1; then
    run "helm list -A -o yaml > '$BACKUP_DIR/helm-releases.yaml' || true"
    run "helm repo list > '$BACKUP_DIR/helm-repos.txt' || true"
  fi
}

backup_control_plane_files() {
  run "tar -C / -czf '$BACKUP_DIR/etc-kubernetes.tgz' etc/kubernetes"
  if [[ -f /var/lib/kubelet/config.yaml ]]; then
    run "cp -a /var/lib/kubelet/config.yaml '$BACKUP_DIR/kubelet-config.yaml'"
  fi
}

etcd_snapshot_if_needed() {
  if [[ "$CONTROL_PLANE" != "true" ]]; then
    return
  fi

  if [[ -f /etc/kubernetes/manifests/etcd.yaml ]]; then
    require_cmd etcdctl
    log "Обнаружен stacked etcd. Снимаю snapshot."
    run "ETCDCTL_API=3 etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
      --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
      endpoint health > '$BACKUP_DIR/etcd-health.txt'"
    run "ETCDCTL_API=3 etcdctl \
      --endpoints=https://127.0.0.1:2379 \
      --cacert=/etc/kubernetes/pki/etcd/ca.crt \
      --cert=/etc/kubernetes/pki/etcd/healthcheck-client.crt \
      --key=/etc/kubernetes/pki/etcd/healthcheck-client.key \
      snapshot save '$BACKUP_DIR/etcd-snapshot.db'"
  else
    warn "Локальный stacked etcd не найден. Если у тебя external etcd — snapshot делай отдельно на etcd members."
  fi
}

ensure_pkgs_repo_minor() {
  local desired_minor="$1"

  if [[ ! -f "$PKG_REPO_FILE" ]]; then
    if [[ "$FORCE_REPO_SWITCH" != "true" ]]; then
      die "Не найден repo file $PKG_REPO_FILE. Создай/проверь его или используй --force-repo-switch."
    fi
    warn "Repo file не найден, но включен --force-repo-switch. Буду создавать новый файл."
  fi

  case "$PKG_FAMILY" in
    apt)
      if [[ -f "$PKG_REPO_FILE" ]] && grep -q 'pkgs\.k8s\.io\|pkgs\.kubernetes\.io\|packages\.kubernetes\.io' "$PKG_REPO_FILE"; then
        run "sed -E -i 's#core:/stable:/v[0-9]+\.[0-9]+/#core:/stable:/v${desired_minor}/#g' '$PKG_REPO_FILE'"
      else
        [[ "$FORCE_REPO_SWITCH" == "true" ]] || die "В $PKG_REPO_FILE не найден pkgs.k8s.io repo. Старый legacy repo нужно мигрировать отдельно."
        run "mkdir -p /etc/apt/keyrings"
        run "printf '%s\n' 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${desired_minor}/deb/ /' > '$PKG_REPO_FILE'"
      fi
      run "apt-get update"
      ;;
    yum|dnf|dnf5)
      if [[ -f "$PKG_REPO_FILE" ]] && grep -q 'pkgs\.k8s\.io\|pkgs\.kubernetes\.io\|packages\.kubernetes\.io' "$PKG_REPO_FILE"; then
        run "sed -E -i 's#core:/stable:/v[0-9]+\.[0-9]+/#core:/stable:/v${desired_minor}/#g' '$PKG_REPO_FILE'"
      else
        [[ "$FORCE_REPO_SWITCH" == "true" ]] || die "В $PKG_REPO_FILE не найден pkgs.k8s.io repo. Старый legacy repo нужно мигрировать отдельно."
        run "cat > '$PKG_REPO_FILE' <<YUMREPO
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${desired_minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${desired_minor}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
YUMREPO"
      fi
      if command -v yum >/dev/null 2>&1; then
        run "yum clean all"
        run "yum makecache"
      elif command -v dnf >/dev/null 2>&1; then
        run "dnf clean all"
        run "dnf makecache"
      elif command -v dnf5 >/dev/null 2>&1; then
        run "dnf5 clean all"
        run "dnf5 makecache"
      fi
      ;;
    *) die "Неподдерживаемый PKG_FAMILY=$PKG_FAMILY" ;;
  esac
}

resolve_pkg_version() {
  local pkg="$1" wanted="$2"
  local pattern
  wanted=$(normalize_version "$wanted")
  if [[ "$wanted" =~ ^[0-9]+\.[0-9]+$ ]]; then
    pattern="^${wanted//./\\.}\\."
  else
    pattern="^${wanted//./\\.}([.-]|$)"
  fi

  case "$PKG_FAMILY" in
    apt)
      apt-cache madison "$pkg" | awk '{print $3}' | grep -E "$pattern" | head -n1
      ;;
    yum)
      yum list --showduplicates "$pkg" --disableexcludes=kubernetes 2>/dev/null | awk 'tolower($1) ~ /^'"$pkg"'([.]|$)/ {print $2}' | grep -E "$pattern" | sort -V | tail -n1
      ;;
    dnf)
      dnf list --showduplicates "$pkg" --disableexcludes=kubernetes 2>/dev/null | awk 'tolower($1) ~ /^'"$pkg"'([.]|$)/ {print $2}' | grep -E "$pattern" | sort -V | tail -n1
      ;;
    dnf5)
      dnf5 list --showduplicates "$pkg" --setopt=disable_excludes=kubernetes 2>/dev/null | awk 'tolower($1) ~ /^'"$pkg"'([.]|$)/ {print $2}' | grep -E "$pattern" | sort -V | tail -n1
      ;;
    *) die "Неподдерживаемый PKG_FAMILY=$PKG_FAMILY" ;;
  esac
}

pkg_install_exact() {
  local pkg="$1" exact="$2"
  [[ -n "$exact" ]] || die "Не удалось определить версию пакета для $pkg"
  case "$PKG_FAMILY" in
    apt)
      if [[ "$pkg" == "kubeadm" ]]; then run "apt-mark unhold kubeadm || true"; fi
      if [[ "$pkg" == "kubelet" || "$pkg" == "kubectl" ]]; then run "apt-mark unhold kubelet kubectl || true"; fi
      run "apt-get update"
      run "DEBIAN_FRONTEND=noninteractive apt-get install -y '$pkg=$exact'"
      if [[ "$pkg" == "kubeadm" ]]; then run "apt-mark hold kubeadm"; fi
      if [[ "$pkg" == "kubelet" || "$pkg" == "kubectl" ]]; then run "apt-mark hold kubelet kubectl"; fi
      ;;
    yum)
      run "yum install -y '${pkg}-${exact}' --disableexcludes=kubernetes"
      ;;
    dnf)
      run "dnf install -y '${pkg}-${exact}' --disableexcludes=kubernetes"
      ;;
    dnf5)
      run "dnf5 install -y '${pkg}-${exact}' --setopt=disable_excludes=kubernetes"
      ;;
  esac
}

build_drain_args() {
  local args=("$NODE_NAME" --ignore-daemonsets --timeout=20m)
  if [[ "$ALLOW_EMPTYDIR_LOSS" == "true" ]]; then
    args+=(--delete-emptydir-data)
  fi
  printf '%q ' "${args[@]}"
}

drain_node() {
  log "Drain node: $NODE_NAME"
  run "kubectl --kubeconfig '$KUBECONFIG_PATH' drain $(build_drain_args)"
}

uncordon_node() {
  log "Uncordon node: $NODE_NAME"
  run "kubectl --kubeconfig '$KUBECONFIG_PATH' uncordon '$NODE_NAME'"
}

verify_node_ready() {
  run "kubectl --kubeconfig '$KUBECONFIG_PATH' wait --for=condition=Ready 'node/$NODE_NAME' --timeout=15m"
  run "kubectl --kubeconfig '$KUBECONFIG_PATH' get node '$NODE_NAME' -o wide"
}

run_kubeadm_step() {
  local step_version="$1"
  CURRENT_STEP_VERSION="$step_version"

  if [[ "$CONTROL_PLANE" == "true" && "$FIRST_CONTROL_PLANE" == "true" ]]; then
    log "Проверяю план upgrade до v$step_version"
    run "kubeadm upgrade plan"
    log "Применяю kubeadm upgrade apply v$step_version"
    run "kubeadm upgrade apply -y 'v$step_version'"
  else
    log "Выполняю kubeadm upgrade node"
    run "kubeadm upgrade node"
  fi
}

upgrade_kube_packages_for_step() {
  local step_version="$1"
  local kubeadm_pkg kubelet_pkg kubectl_pkg

  kubeadm_pkg=$(resolve_pkg_version kubeadm "$step_version")
  [[ -n "$kubeadm_pkg" ]] || die "Не найдена версия kubeadm для шага $step_version"
  pkg_install_exact kubeadm "$kubeadm_pkg"

  run_kubeadm_step "$step_version"
  drain_node

  kubelet_pkg=$(resolve_pkg_version kubelet "$step_version")
  kubectl_pkg=$(resolve_pkg_version kubectl "$step_version")
  [[ -n "$kubelet_pkg" ]] || die "Не найдена версия kubelet для шага $step_version"
  [[ -n "$kubectl_pkg" ]] || die "Не найдена версия kubectl для шага $step_version"
  pkg_install_exact kubelet "$kubelet_pkg"
  pkg_install_exact kubectl "$kubectl_pkg"

  run "systemctl daemon-reload"
  run "systemctl restart kubelet"
  verify_node_ready
  uncordon_node
}

current_cluster_minor_from_local() {
  version_major_minor "$(current_local_kubelet_version)"
}

check_jump_host_kubectl_skew_if_possible() {
  [[ -n "$KUBECONFIG_PATH" && -f "$KUBECONFIG_PATH" ]] || return 0

  local server_version server_minor target_minor server_minor_n target_minor_n diff
  server_version=$(kubectl --kubeconfig "$KUBECONFIG_PATH" version -o yaml 2>/dev/null | awk '
    /serverVersion:/ {in_server=1; next}
    in_server && /gitVersion:/ {print $2; exit}
  ' | sed 's/^v//; s/"//g')
  [[ -n "$server_version" ]] || return 0

  server_minor=$(version_major_minor "$server_version")
  target_minor=$(version_major_minor "$TARGET_VERSION")
  server_minor_n=${server_minor#*.}
  target_minor_n=${target_minor#*.}
  diff=$(( target_minor_n - server_minor_n ))
  if (( diff < 0 )); then
    diff=$(( -diff ))
  fi

  if (( diff > 1 )); then
    die "Целевой kubectl v$TARGET_VERSION выходит за поддерживаемый skew относительно kube-apiserver v$server_version. Для jump host kubectl должен быть в пределах одной minor-версии от control plane."
  fi
}

execute_jump_host_upgrade() {
  local current_version target_minor kubectl_pkg
  current_version=$(current_local_kubectl_version)
  [[ -n "$current_version" ]] || die "Не удалось определить текущую версию kubectl."

  if ! version_lt "$current_version" "$TARGET_VERSION" && ! version_eq "$current_version" "$TARGET_VERSION"; then
    die "Локальная версия kubectl $current_version новее целевой $TARGET_VERSION."
  fi

  if version_eq "$current_version" "$TARGET_VERSION"; then
    log "Jump host уже на целевой версии kubectl v$TARGET_VERSION."
    return
  fi

  check_jump_host_kubectl_skew_if_possible

  target_minor=$(version_major_minor "$TARGET_VERSION")
  log "Jump host: обновляю только kubectl до v$TARGET_VERSION"
  ensure_pkgs_repo_minor "$target_minor"
  kubectl_pkg=$(resolve_pkg_version kubectl "$TARGET_VERSION")
  [[ -n "$kubectl_pkg" ]] || die "Не найдена версия kubectl для $TARGET_VERSION"
  pkg_install_exact kubectl "$kubectl_pkg"
  run "kubectl version --client"
  if [[ -n "$KUBECONFIG_PATH" && -f "$KUBECONFIG_PATH" ]]; then
    run "kubectl --kubeconfig '$KUBECONFIG_PATH' version"
  fi
}

execute_upgrade() {
  if [[ "$ROLE" == "jump-host" ]]; then
    execute_jump_host_upgrade
    return
  fi

  local current_version current_minor target_minor next_minor step_version
  current_version=$(current_local_kubelet_version)
  target_minor=$(version_major_minor "$TARGET_VERSION")

  if ! version_lt "$current_version" "$TARGET_VERSION" && ! version_eq "$current_version" "$TARGET_VERSION"; then
    die "Локальная версия $current_version новее целевой $TARGET_VERSION."
  fi

  if version_eq "$current_version" "$TARGET_VERSION"; then
    log "Node уже на целевой версии $TARGET_VERSION."
    return
  fi

  while version_lt "$current_version" "$TARGET_VERSION"; do
    current_minor=$(version_major_minor "$current_version")

    if [[ "$current_minor" != "$target_minor" ]]; then
      next_minor=$(bump_minor "$current_version")
      log "Minor upgrade: $current_minor -> $next_minor"
      ensure_pkgs_repo_minor "$next_minor"
      step_version=$(resolve_pkg_version kubeadm "$next_minor")
      [[ -n "$step_version" ]] || die "Не удалось найти latest patch для minor $next_minor"
      step_version=$(normalize_version "${step_version%%-*}")
    else
      log "Patch/final upgrade: $current_minor -> $(normalize_version "$TARGET_VERSION")"
      ensure_pkgs_repo_minor "$target_minor"
      step_version="$TARGET_VERSION"
    fi

    log "Шаг upgrade до v$step_version"
    upgrade_kube_packages_for_step "$step_version"
    current_version=$(current_local_kubelet_version)
    current_version=$(normalize_version "$current_version")
    if ! version_eq "$current_version" "$step_version"; then
      warn "Ожидалась локальная kubelet версия $step_version, получена $current_version"
    fi
  done
}

update_helm_if_requested() {
  [[ "$UPDATE_HELM" == "true" ]] || return 0
  require_cmd tar mktemp uname

  local tmp arch url
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *) die "Helm update пока поддерживает только amd64/arm64. Обнаружено: $arch" ;;
  esac

  tmp=$(mktemp -d)
  url="https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-4"
  log "Обновляю Helm через официальный installer script Helm 4"
  run "curl -fsSL -o '$tmp/get_helm.sh' '$url'"
  run "chmod 700 '$tmp/get_helm.sh'"
  run "HELM_INSTALL_DIR=/usr/local/bin '$tmp/get_helm.sh'"
  run "helm version"
  run "rm -rf '$tmp'"
}

rollback_node_local() {
  local md repo_backup prev_kubeadm prev_kubelet prev_kubectl repo_file
  BACKUP_DIR="$ROLLBACK_FROM"
  md="$BACKUP_DIR/metadata.env"
  [[ -d "$BACKUP_DIR" ]] || die "Каталог backup не найден: $BACKUP_DIR"
  [[ -f "$md" ]] || die "Не найден metadata file: $md"
  # shellcheck disable=SC1090
  source "$md"

  log "Node-local rollback из $BACKUP_DIR"
  detect_pkg_family
  repo_file="$PKG_REPO_FILE"

  repo_backup="$BACKUP_DIR/$(basename "$repo_file").bak"
  if [[ -f "$repo_backup" ]]; then
    run "cp -a '$repo_backup' '$repo_file'"
  fi

  if [[ -n "${PREV_KUBEADM:-}" ]]; then
    ensure_pkgs_repo_minor "$(version_major_minor "$PREV_KUBEADM")"
    pkg_install_exact kubeadm "$(resolve_pkg_version kubeadm "$PREV_KUBEADM")"
  fi
  if [[ -n "${PREV_KUBELET:-}" ]]; then
    ensure_pkgs_repo_minor "$(version_major_minor "$PREV_KUBELET")"
    pkg_install_exact kubelet "$(resolve_pkg_version kubelet "$PREV_KUBELET")"
  fi
  if [[ -n "${PREV_KUBECTL:-}" ]]; then
    ensure_pkgs_repo_minor "$(version_major_minor "$PREV_KUBECTL")"
    pkg_install_exact kubectl "$(resolve_pkg_version kubectl "$PREV_KUBECTL")"
  fi

  if [[ -f "$BACKUP_DIR/etc-kubernetes.tgz" ]]; then
    run "tar -C / -xzf '$BACKUP_DIR/etc-kubernetes.tgz'"
  fi
  if [[ -f "$BACKUP_DIR/kubelet-config.yaml" ]]; then
    run "cp -a '$BACKUP_DIR/kubelet-config.yaml' /var/lib/kubelet/config.yaml"
  fi

  run "systemctl daemon-reload"
  run "systemctl restart kubelet"
  warn "Node-local rollback завершен."
  if [[ -f "$BACKUP_DIR/etcd-snapshot.db" ]]; then
    warn "Внимание: etcd snapshot найден ($BACKUP_DIR/etcd-snapshot.db), но автоматический cluster-state restore намеренно НЕ выполнялся."
    warn "Полный restore etcd нужно делать согласованно по процедуре disaster recovery, а не автоматически на одной node."
  fi
}

main() {
  parse_args "$@"

  if [[ -n "$ROLLBACK_FROM" ]]; then
    rollback_node_local
    exit 0
  fi

  preflight_common
  prepare_backup_dir
  save_metadata
  backup_repo_file
  backup_cluster_views
  if [[ "$CONTROL_PLANE" == "true" ]]; then
    backup_control_plane_files
    etcd_snapshot_if_needed
  fi

  log "Старт upgrade: role=$ROLE first_control_plane=$FIRST_CONTROL_PLANE node=${NODE_NAME:-n/a} target=v$TARGET_VERSION"
  execute_upgrade
  update_helm_if_requested

  if [[ "$ROLE" == "jump-host" ]]; then
    log "Готово. Jump host обновлен: kubectl v$(current_local_kubectl_version)."
  else
    log "Готово. Node $NODE_NAME обновлена до Kubernetes v$(current_local_kubelet_version)."
  fi
  log "Backup'и: $BACKUP_DIR"
  if [[ "$CONTROL_PLANE" == "true" ]]; then
    warn "Не забудь отдельно проверить/обновить CNI, device plugins и манифесты с устаревшими API версиями."
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
