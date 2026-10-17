#!/usr/bin/env bash
#
# 构建并推送 DB Backup 镜像到私有镜像仓库
#
#   docker build（仓库根目录 Dockerfile：前端 pnpm 构建 + mydumper/nginx/Flask 运行镜像）
#     -> 打标签 192.168.0.201:5000/anchovypublic/db-backup-management:latest
#     -> docker push
#
# 本脚本「只负责构建与推送」，不涉及部署；何时拉取/上线由运维决定。
#
# ---------------------------------------------------------------------------
# 快速开始
# ---------------------------------------------------------------------------
#   ./build-push-image.sh                  # 构建并推送 :latest
#   ./build-push-image.sh --build-only     # 只本地构建，不推送
#   ./build-push-image.sh --also-tag v1.2.3
#   ./build-push-image.sh --platform linux/amd64,linux/arm64   # 多架构（需 buildx）
#   ./build-push-image.sh --no-cache
#   ./build-push-image.sh --login          # 先 docker login 再推送（私仓需鉴权时）
#
# ---------------------------------------------------------------------------
# 可用环境变量（命令行参数优先）
# ---------------------------------------------------------------------------
#   REGISTRY      镜像仓库地址，默认 192.168.0.201:5000
#   NAMESPACE     命名空间，默认 anchovypublic
#   IMAGE_NAME    镜像名，默认 db-backup-management
#   TAG           标签，默认 latest
#   PLATFORMS     目标平台（逗号分隔）；留空=构建机原生平台
#   DOCKERFILE    Dockerfile 路径，默认 <仓库根>/Dockerfile
#   EXTRA_TAGS    追加标签（空格分隔）
#   NODE_IMAGE    前端构建基础镜像，默认 <REGISTRY>/<NAMESPACE>/node:22-slim
#   MYDUMPER_IMAGE 运行基础镜像，默认 <REGISTRY>/<NAMESPACE>/mydumper:v0.21.3-2
#
set -euo pipefail

# ------------------------------- 默认配置 ---------------------------------
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${SCRIPT_DIR}"

REGISTRY="${REGISTRY:-192.168.0.201:5000}"
NAMESPACE="${NAMESPACE:-anchovypublic}"
IMAGE_NAME="${IMAGE_NAME:-db-backup-management}"
TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-}"
DOCKERFILE="${DOCKERFILE:-${REPO_ROOT}/Dockerfile}"
EXTRA_TAGS="${EXTRA_TAGS:-}"

# 基础镜像：留空则解析为「本私仓同名镜像」（见参数解析之后），避免构建时依赖外网
NODE_IMAGE="${NODE_IMAGE:-}"
MYDUMPER_IMAGE="${MYDUMPER_IMAGE:-}"

BUILD_ONLY=0
NO_CACHE=0
DO_LOGIN=0
LOG_FILE="${SCRIPT_DIR}/build-push-image.log"

# 运行期填充：最终镜像的完整标签列表
TAGS=()

# ------------------------------- 工具函数 ---------------------------------
log() { printf '%s\n' "$*" | tee -a "${LOG_FILE}"; }
info() { log "[INFO] $*"; }
warn() { log "[WARN] $*" >&2; }

die() {
  log "[ERROR] $*" >&2
  exit 1
}

usage() {
  sed -n '2,33p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit 0
}

# ------------------------------- 参数解析 ---------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --registry) REGISTRY="$2"; shift 2 ;;
    --namespace) NAMESPACE="$2"; shift 2 ;;
    --image) IMAGE_NAME="$2"; shift 2 ;;
    --tag) TAG="$2"; shift 2 ;;
    --also-tag) EXTRA_TAGS="${EXTRA_TAGS} $2"; shift 2 ;;
    --platform) PLATFORMS="$2"; shift 2 ;;
    --dockerfile) DOCKERFILE="$2"; shift 2 ;;
    --node-image) NODE_IMAGE="$2"; shift 2 ;;
    --mydumper-image) MYDUMPER_IMAGE="$2"; shift 2 ;;
    --build-only) BUILD_ONLY=1; shift ;;
    --no-cache) NO_CACHE=1; shift ;;
    --login) DO_LOGIN=1; shift ;;
    -h|--help) usage ;;
    *) die "未知参数: $1（使用 --help 查看用法）" ;;
  esac
done

FULL_IMAGE="${REGISTRY}/${NAMESPACE}/${IMAGE_NAME}"
# 基础镜像未显式指定时，默认取本私仓的对应镜像（与 REGISTRY/NAMESPACE 联动）
NODE_IMAGE="${NODE_IMAGE:-${REGISTRY}/${NAMESPACE}/node:22-slim}"
MYDUMPER_IMAGE="${MYDUMPER_IMAGE:-${REGISTRY}/${NAMESPACE}/mydumper:v0.21.3-2}"
MULTI_ARCH=0
[[ "${PLATFORMS}" == *,* ]] && MULTI_ARCH=1

# ------------------------------- 前置检查 ---------------------------------
preflight() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker 命令，请先安装 Docker"
  docker info >/dev/null 2>&1 || die "Docker 守护进程不可用（docker info 失败）；请确认 Docker 已启动、且当前用户在 docker 组"

  [[ -f "${DOCKERFILE}" ]] || die "Dockerfile 不存在: ${DOCKERFILE}"
  [[ -f "${REPO_ROOT}/web/package.json" ]] || die "构建上下文异常：缺少 web/package.json（请在仓库根目录运行本脚本）"

  if [[ -n "${PLATFORMS}" ]]; then
    docker buildx version >/dev/null 2>&1 || die "指定了 --platform，但未安装 docker buildx"
    if [[ ${MULTI_ARCH} -eq 1 && ${BUILD_ONLY} -eq 1 ]]; then
      die "多架构镜像无法保存为本地镜像（--build-only 与多个平台冲突）；请去掉 --build-only，或只指定单一平台"
    fi
  fi

  # 私仓多为 HTTP：未配置 insecure-registries 时 push 会报 HTTPS/HTTP 错误，提前给出修复指引
  if [[ ${BUILD_ONLY} -eq 0 ]] && ! docker info 2>/dev/null | grep -qF -- "${REGISTRY}"; then
    warn "未在 docker 配置中检测到仓库地址 ${REGISTRY}。"
    warn "若该私仓使用 HTTP（非 HTTPS），push 会失败。请把地址加入 /etc/docker/daemon.json 后重启 docker："
    warn "  { \"insecure-registries\": [\"${REGISTRY}\"] }"
  fi

  info "镜像: ${FULL_IMAGE}:${TAG}"
  info "上下文: ${REPO_ROOT}"
  info "Dockerfile: ${DOCKERFILE}"
  info "基础镜像: node=${NODE_IMAGE} | mydumper=${MYDUMPER_IMAGE}"
  info "平台: ${PLATFORMS:-（构建机原生）}"
}

# ------------------------------- 组装标签 ---------------------------------
build_tags() {
  TAGS=( "${FULL_IMAGE}:${TAG}" )
  local t
  for t in ${EXTRA_TAGS}; do
    [[ -n "${t}" ]] && TAGS+=( "${FULL_IMAGE}:${t}" )
  done
}

# ------------------------------- 登录私仓 ---------------------------------
do_login() {
  [[ ${DO_LOGIN} -eq 1 ]] || return 0
  info "登录镜像仓库 ${REGISTRY} ..."
  docker login "${REGISTRY}"
}

# ------------------------------- 构建镜像 ---------------------------------
build_image() {
  local cache_flag=()
  [[ ${NO_CACHE} -eq 1 ]] && cache_flag=( --no-cache )

  local build_args=(
    --build-arg "NODE_IMAGE=${NODE_IMAGE}"
    --build-arg "MYDUMPER_IMAGE=${MYDUMPER_IMAGE}"
  )

  if [[ -n "${PLATFORMS}" ]]; then
    # 指定平台走 buildx；多架构只能直接推送，无法落到本地镜像
    local push_flag=( --load )
    [[ ${BUILD_ONLY} -eq 0 ]] && push_flag=( --push )

    info "docker buildx 构建（platform=${PLATFORMS}）..."
    local tag_args=()
    local t
    for t in "${TAGS[@]}"; do tag_args+=( -t "${t}" ); done

    docker buildx build \
      --file "${DOCKERFILE}" \
      --platform "${PLATFORMS}" \
      "${build_args[@]}" \
      "${tag_args[@]}" \
      "${cache_flag[@]}" \
      "${push_flag[@]}" \
      "${REPO_ROOT}"
    return 0
  fi

  # 默认路径：普通 docker build（镜像落在本地），随后逐标签 push
  info "docker build 构建 ..."
  local tag_args=()
  local t
  for t in "${TAGS[@]}"; do tag_args+=( -t "${t}" ); done

  docker build \
    --file "${DOCKERFILE}" \
    "${build_args[@]}" \
    "${tag_args[@]}" \
    "${cache_flag[@]}" \
    "${REPO_ROOT}"
}

# ------------------------------- 推送镜像 ---------------------------------
push_image() {
  [[ ${BUILD_ONLY} -eq 1 ]] && { info "已跳过推送（--build-only）"; return 0; }

  # 指定平台时由 buildx --push 在构建阶段完成推送
  if [[ -n "${PLATFORMS}" ]]; then
    info "镜像已由 buildx --push 推送"
    return 0
  fi

  local t
  for t in "${TAGS[@]}"; do
    info "推送 ${t} ..."
    docker push "${t}"
  done
}

# ------------------------------- 结果汇总 ---------------------------------
summary() {
  echo "" | tee -a "${LOG_FILE}"
  info "完成。镜像标签："
  local t
  for t in "${TAGS[@]}"; do log "  - ${t}"; done
  echo "" | tee -a "${LOG_FILE}"
  if [[ ${BUILD_ONLY} -eq 1 ]]; then
    log "（仅本地构建，未推送）"
  else
    log "部署由运维在目标机器执行，例如："
    log "  docker pull ${FULL_IMAGE}:${TAG}"
    log "  docker run -d -p 5555:5555 -v /宿主机/backup_data:/app/backup_data --name db-backup ${FULL_IMAGE}:${TAG}"
  fi
}

# ------------------------------- 主流程 -----------------------------------
main() {
  : > "${LOG_FILE}"
  info "开始（日志: ${LOG_FILE}）"
  preflight
  build_tags
  do_login
  build_image
  push_image
  summary
}

main "$@"
