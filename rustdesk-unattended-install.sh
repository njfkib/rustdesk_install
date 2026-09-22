#!/usr/bin/env bash
# =============================================================================
# RustDesk Server 无人值守一键安装脚本 (基于 nas-tool/rustdesk_install)
# 项目地址: https://github.com/nas-tool/rustdesk_install
#
# 功能:
#   通过参数自动完成官方安装器的全部交互(部署方式/IP/域名/覆盖确认),
#   实现真正无人值守, 适合脚本化/定时/批量部署。
#
# 用法:
#   # 公网IP模式(自动探测出口公网IP, 无需手动填)
#   sudo bash rustdesk-unattended-install.sh --mode public
#
#   # 域名模式(DDNS)
#   sudo bash rustdesk-unattended-install.sh --mode domain --host my.ddns.com
#
#   # 内网静态IP模式
#   sudo bash rustdesk-unattended-install.sh --mode lan --ip 192.168.1.100
#
#   # 已安装过时覆盖重装(默认拒绝覆盖)
#   sudo bash rustdesk-unattended-install.sh --mode public --overwrite=yes
#
#   # 国内加速 / 指定架构 / 指定版本 / 预检
#   sudo MIRROR=https://gh-proxy.com/ bash rustdesk-unattended-install.sh --mode public
#   sudo bash rustdesk-unattended-install.sh --mode lan --ip 10.0.0.8 --arch amd64 --tag main-xxx --dry-run
# =============================================================================
set -euo pipefail

REPO="nas-tool/rustdesk_install"
API_LATEST="https://api.github.com/repos/${REPO}/releases/latest"
RELEASE_BASE="https://github.com/${REPO}/releases/download"

MIRROR="${MIRROR:-}"
DEST_DIR="${DEST_DIR:-/tmp/rustdesk_install}"
MODE=""
HOST=""
ARCH_OPT=""
TAG_OPT=""
OVERWRITE=0
DRY_RUN=0

usage() {
  cat <<'EOF'
RustDesk 服务端无人值守一键安装脚本 (基于 nas-tool/rustdesk_install)

用法:
  sudo bash rustdesk-unattended-install.sh --mode public
  sudo bash rustdesk-unattended-install.sh --mode domain --host <域名>
  sudo bash rustdesk-unattended-install.sh --mode lan --ip <静态IP>

必选参数:
  --mode <public|domain|lan>   部署方式: 公网IP / 域名(DDNS) / 内网手动IP

可选参数:
  --host <域名>                模式为 domain 时必填
  --ip <IP>                    模式为 lan 时必填 (与 --host 等价)
  --overwrite=yes              服务器已安装时自动覆盖重装, 默认拒绝
  --arch <arch>                手动指定架构 (amd64|arm64|armv7)
  --tag <tag>                  指定 Release 版本号, 默认最新版
  --mirror <prefix>            下载镜像前缀, 如 https://gh-proxy.com/
  --dry-run                    预检: 只打印将执行的命令与自动输入序列
  --help                       显示本帮助

环境变量:
  MIRROR              同 --mirror
  DEST_DIR            安装器下载目录, 默认 /tmp/rustdesk_install

说明:
  - 需要 root 权限
  - 公网IP模式由官方安装器自动获取出口公网IP, 无需填写
  - 安装完成后 Key 在 /opt/rustdesk/id_ed25519.pub
EOF
}

# ---- 参数解析 -------------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    --mode)           MODE="$2"; shift ;;
    --host)           HOST="$2"; shift ;;
    --ip)             HOST="$2"; shift ;;
    --overwrite=yes)  OVERWRITE=1 ;;
    --overwrite=no)   OVERWRITE=0 ;;
    --arch)           ARCH_OPT="$2"; shift ;;
    --tag)            TAG_OPT="$2"; shift ;;
    --mirror)         MIRROR="$2"; shift ;;
    --dry-run)        DRY_RUN=1 ;;
    --help|-h)        usage; exit 0 ;;
    *)
      case "$1" in
        --overwrite=*) echo "[错误] 无效参数: $1 (仅支持 --overwrite=yes|no)" >&2; exit 1 ;;
        *) echo "[错误] 未知参数: $1 (使用 --help 查看帮助)" >&2; exit 1 ;;
      esac
      ;;
  esac
  shift
done

case "$MODE" in
  public)  : ;;
  domain)  [ -n "$HOST" ] || { echo "[错误] --mode domain 必须提供 --host <域名>" >&2; exit 1; } ;;
  lan)     [ -n "$HOST" ] || { echo "[错误] --mode lan 必须提供 --ip <静态IP>" >&2; exit 1; } ;;
  "")      echo "[错误] 缺少必选参数 --mode <public|domain|lan>" >&2; usage >&2; exit 1 ;;
  *)       echo "[错误] 无效模式: $MODE (仅支持 public/domain/lan)" >&2; exit 1 ;;
esac

# ---- 工具检查 -------------------------------------------------------------
for c in curl uname grep sed; do
  command -v "$c" >/dev/null 2>&1 || { echo "[错误] 缺少命令: $c" >&2; exit 1; }
done
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1

# ---- 架构检测 -------------------------------------------------------------
detect_arch() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)   echo "amd64" ;;
    aarch64|arm64)  echo "arm64" ;;
    armv7l|armv7|armhf) echo "armv7" ;;
    *) echo "unsupported" ;;
  esac
}

fetch_latest_json() {
  local json
  json="$(curl -fsSL --connect-timeout 10 "$API_LATEST" 2>/dev/null || true)"
  if [ -z "$json" ]; then
    echo "[错误] 无法访问 GitHub API: $API_LATEST" >&2
    echo "        国内网络可尝试: sudo MIRROR=https://gh-proxy.com/ bash $(basename "$0")" >&2
    exit 1
  fi
  echo "$json"
}

parse_tag() {
  local json="$1" line
  if [ "$HAVE_JQ" -eq 1 ]; then
    echo "$json" | jq -r '.tag_name'
  else
    line="$(echo "$json" | grep -o '"tag_name":[^,]*' | head -1 || true)"
    [ -n "$line" ] || { echo "[错误] 无法解析 Release 信息" >&2; exit 1; }
    echo "$line" | sed 's/.*: *"//; s/"$//'
  fi
}

parse_digest() {
  local json="$1" asset="$2"
  if [ "$HAVE_JQ" -eq 1 ]; then
    echo "$json" | jq -r --arg a "$asset" '.assets[] | select(.name==$a) | .digest' 2>/dev/null | sed 's/^sha256://'
  fi
}

# ---- 构造官方安装器的自动输入序列 ------------------------------------------
# 官方交互流程:
#   1) 若已安装: Menu(1=覆盖安装, 2=卸载, 3=取消) -> "1"
#   2) 部署方式: Menu(1=公网IP, 2=域名, 3=内网手动IP)
#   3) 域名模式: Input(域名); 若解析IP与出口IP不一致 -> YesNo, 应答 "y"
#   4) 内网模式: Input(静态IP)
# 预置/y\ 用于金色确认分支; 未触发时该输入不会被消费, 无副作用。
build_input() {
  local input=""
  if [ -f /opt/rustdesk/hbbs ] && [ -f /opt/rustdesk/hbbr ]; then
    echo "[提示] 检测到已安装, 按参数执行覆盖安装" >&2
    input="${input}1\\n"
  fi
  case "$MODE" in
    public)  input="${input}1\\n" ;;
    domain)  input="${input}2\\n${HOST}\\ny\\n" ;;
    lan)     input="${input}3\\n${HOST}\\n" ;;
  esac
  echo "$input"
}

# ---- 主流程 ---------------------------------------------------------------
echo "=================================================="
echo " RustDesk Server 无人值守安装 (nas-tool/rustdesk_install)"
echo "=================================================="

ARCH="$ARCH_OPT"
if [ -z "$ARCH" ]; then
  ARCH="$(detect_arch)"
  if [ "$ARCH" = "unsupported" ]; then
    echo "[错误] 不支持的架构: $(uname -m), 仅支持 amd64/arm64/armv7" >&2
    exit 1
  fi
fi

if [ -f /opt/rustdesk/hbbs ] && [ -f /opt/rustdesk/hbbr ] && [ "$OVERWRITE" != "1" ]; then
  echo "[错误] 检测到 /opt/rustdesk 已安装 RustDesk 服务端。" >&2
  echo "       如需覆盖重装请加 --overwrite=yes; 如不想动现有环境请勿运行本脚本。" >&2
  exit 1
fi

INPUT_SEQ="$(build_input)"

if [ "$DRY_RUN" = "1" ]; then
  echo "==> 预检模式, 不执行任何下载与安装"
  echo "==> 目标架构   : $ARCH"
  echo "==> 部署方式   : $MODE"
  [ -n "$HOST" ] && echo "==> 主机地址   : $HOST"
  [ -n "$TAG_OPT" ] && echo "==> 固定版本   : $TAG_OPT"
  [ -n "$MIRROR" ] && echo "==> 下载镜像   : $MIRROR"
  echo "==> 覆盖重装   : $([ "$OVERWRITE" = "1" ] && echo yes || echo no)"
  echo "==> 自动输入序列(发送给官方安装器):"
  printf '   %b' "$INPUT_SEQ" | sed 's/\\n$//; s/\\n/\n   /g'
  echo
  echo "==> 预检完成, 无问题。"
  exit 0
fi

# ---- root 权限检查(仅真实安装前) -------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "[错误] 请以 root 权限运行: sudo bash $(basename "$0")" >&2
  exit 1
fi

JSON_LATEST=""
TAG="$TAG_OPT"
if [ -z "$TAG" ]; then
  echo "==> 正在获取最新 Release ..."
  JSON_LATEST="$(fetch_latest_json)"
  TAG="$(parse_tag "$JSON_LATEST")"
fi
echo "==> Release 版本: $TAG"

ASSET="rustdesk_install_linux-${ARCH}"
URL="${RELEASE_BASE}/${TAG}/${ASSET}"
if [ -n "$MIRROR" ]; then
  URL="${MIRROR}${URL}"
  echo "==> 使用下载镜像: $MIRROR"
fi

mkdir -p "$DEST_DIR"
BIN="${DEST_DIR}/${ASSET}"

echo "==> 下载: $URL"
curl -fSL --retry 3 --connect-timeout 15 -o "$BIN" "$URL"
echo "==> 下载完成: $BIN"

if [ -n "$JSON_LATEST" ] && [ "$HAVE_JQ" -eq 1 ]; then
  EXPECTED="$(parse_digest "$JSON_LATEST" "$ASSET")"
  if [ -n "$EXPECTED" ] && command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$BIN" | awk '{print $1}')"
    if [ "$ACTUAL" != "$EXPECTED" ]; then
      echo "[错误] sha256 校验失败, 文件可能损坏或镜像异常" >&2
      exit 1
    fi
    echo "==> sha256 校验通过"
  fi
elif [ -n "$JSON_LATEST" ]; then
  echo "[提示] 未安装 jq, 跳过 sha256 校验"
fi

chmod +x "$BIN"

# 将输入序列写入临时文件, 以官方安装器自身的退出码为准
IN_SEQ_FILE="$(mktemp)"
trap 'rm -f "$IN_SEQ_FILE"' EXIT
printf '%b' "$INPUT_SEQ" > "$IN_SEQ_FILE"

echo "==> 启动无人值守安装(自动应答), 请等待完成..."
set +e
"$BIN" < "$IN_SEQ_FILE"
RC=$?
set -e

if [ "$RC" -ne 0 ]; then
  echo "[错误] 安装器退出码: $RC, 安装未完成" >&2
  exit "$RC"
fi

echo "=================================================="
echo " 安装流程已结束。"
echo " ID服务器地址: 部署时填写的 ${MODE} 地址"
echo " Key          : cat /opt/rustdesk/id_ed25519.pub"
echo " 日志目录     : /var/log/rustdesk"
echo "=================================================="