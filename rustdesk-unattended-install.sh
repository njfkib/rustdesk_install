#!/usr/bin/env bash
# =============================================================================
# RustDesk Server 无人值守一键安装脚本 v2 (自包含部署版)
#
# 背景: 原 nas-tool/rustdesk_install 安装器将下载源写死在
#       https://files.wanghaoyu.com.cn:8443 (该域名已失效, DNS 无记录),
#       且其下载逻辑每次强制覆盖下载、不检查本地文件, 无法预置绕过。
#       故本脚本不再依赖官方安装器, 自包含实现完整部署流程:
#       直接从 GitHub 官方 rustdesk/rustdesk-server Releases 下载组件,
#       复刻官方安装器的解压/移动/systemd 配置/密钥输出逻辑。
#
# 功能:
#   - 自动检测架构并匹配官方组件包 (amd64 / arm64v8 / armv7)
#   - 自动获取最新 Release 版本并按资产 sha256 校验完整性
#   - 支持公网IP/域名/内网IP 三种部署方式
#   - 默认交互引导: 运行时弹出菜单手动选择部署方式
#   - 也可用 --mode 参数直接指定, 实现无人值守(非交互)
#   - systemd 环境生成并启用系统服务; 否则以后台进程方式运行
#
# 用法:
#   # 交互引导(推荐): 运行时弹出菜单, 手动选择 公网IP/域名/内网IP
#   sudo bash rustdesk-unattended-install.sh
#
#   # 公网IP模式(自动探测出口公网IP, 无人值守)
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
#   sudo bash rustdesk-unattended-install.sh --mode lan --ip 10.0.0.8 --arch amd64 --tag 1.1.16 --dry-run
# =============================================================================
set -euo pipefail
 
SRV_REPO="rustdesk/rustdesk-server"
API_LATEST="https://api.github.com/repos/${SRV_REPO}/releases/latest"
RELEASE_ROOT="https://github.com/${SRV_REPO}/releases/download"
INSTALL_DIR="/opt/rustdesk"
LOG_DIR="/var/log/rustdesk"
SYSTEMD_DIR="/etc/systemd/system"
HBS_PORT="21116"
HBR_PORT="21117"
 
MIRROR="${MIRROR:-}"
WORK_DIR="${WORK_DIR:-/tmp/rustdesk_install}"
MODE=""
HOST=""
ARCH_OPT=""
TAG_OPT=""
OVERWRITE=0
DRY_RUN=0
 
usage() {
  cat <<'EOF'
RustDesk 服务端一键安装脚本 (自包含部署版)
 
用法:
  sudo bash rustdesk-unattended-install.sh                     # 交互引导: 菜单选择部署方式
  sudo bash rustdesk-unattended-install.sh --mode public       # 无人值守: 公网IP
  sudo bash rustdesk-unattended-install.sh --mode domain --host <域名>
  sudo bash rustdesk-unattended-install.sh --mode lan --ip <静态IP>
 
参数(全部可选):
  --mode <public|domain|lan>   部署方式: 公网IP / 域名(DDNS) / 内网手动IP
                               缺省时进入交互菜单手动选择
  --host <域名>                模式为 domain 时使用
  --ip <IP>                    模式为 lan 时使用 (与 --host 等价)
  --overwrite=yes              服务器已安装时自动覆盖重装, 默认拒绝
  --arch <arch>                手动指定架构 (amd64|arm64|armv7)
  --tag <tag>                  rustdesk-server 版本号, 默认最新版
  --mirror <prefix>            下载镜像前缀(如 GitHub 加速), 如 https://gh-proxy.com/
  --dry-run                    预检: 只打印执行计划与参数, 不下载不安装
  --help                       显示本帮助
 
环境变量:
  MIRROR              同 --mirror
  WORK_DIR            组件包下载目录, 默认 /tmp/rustdesk_install
 
说明:
  - 需要 root 权限
  - 公网IP模式由脚本自动获取出口公网IP(ip-api.com, 失败时尝试 ipify)
  - 域名模式会解析域名以校验可达性; 解析IP与出口IP不一致时打印警告并继续
  - 安装完成后 Key 在 /opt/rustdesk/id_ed25519.pub
EOF
}
 
# ---- 部署方式手动选择引导 --------------------------------------------------
# 未指定 --mode 时交互式询问部署方式; 兼容管道输入(echo "2" | bash setup.sh)
guided_mode_select() {
  local choice=""
  echo "=================================================="
  echo " 请选择部署方式:"
  echo "   1) 公网IP     自动探测出口公网IP"
  echo "   2) 域名(DDNS) 需指定已解析到本机的域名"
  echo "   3) 内网手动IP 需指定静态内网IP"
  echo "=================================================="
  while [ -z "$choice" ]; do
    read -r -p "请选择 [1/2/3]: " choice || true
    case "$choice" in
      1) MODE="public" ;;
      2)
        MODE="domain"
        read -r -p "请输入域名(如 rd.example.com): " HOST || true
        if [ -z "$HOST" ]; then
          echo "[错误] 域名不能为空" >&2
          choice=""
        fi
        ;;
      3)
        MODE="lan"
        read -r -p "请输入内网IP(如 192.168.1.100): " HOST || true
        if [ -z "$HOST" ]; then
          echo "[错误] IP 不能为空" >&2
          choice=""
        fi
        ;;
      *)
        echo "[错误] 无效选择: $choice (请输入 1/2/3)" >&2
        choice=""
        ;;
    esac
  done
  echo "==> 已选择部署方式: $MODE${HOST:+ / $HOST}"
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
 
# 未指定 --mode 时进入手动选择引导
if [ -z "$MODE" ]; then
  guided_mode_select
fi
 
case "$MODE" in
  public)  : ;;
  domain)  [ -n "$HOST" ] || { echo "[错误] --mode domain 必须提供 --host <域名>" >&2; exit 1; } ;;
  lan)     [ -n "$HOST" ] || { echo "[错误] --mode lan 必须提供 --ip <静态IP>" >&2; exit 1; } ;;
  *)       echo "[错误] 无效模式: $MODE (仅支持 public/domain/lan)" >&2; exit 1 ;;
esac
 
# ---- 工具检查 -------------------------------------------------------------
for c in curl uname grep sed; do
  command -v "$c" >/dev/null 2>&1 || { echo "[错误] 缺少命令: $c" >&2; exit 1; }
done
HAVE_JQ=0
command -v jq >/dev/null 2>&1 && HAVE_JQ=1
 
# ---- 架构检测与组件包映射 (与官方 installer.go 一致) -------------------------
detect_plan() {
  local m
  m="$(uname -m)"
  case "$m" in
    x86_64|amd64)  echo "x86_64 rustdesk-server-linux-amd64.zip" ;;
    aarch64|arm64) echo "aarch64 rustdesk-server-linux-arm64v8.zip" ;;
    armv7l|armv7|armhf) echo "armv7l rustdesk-server-linux-armv7.zip" ;;
    *) echo "unsupported unsupported" ;;
  esac
}
 
# ---- 获取出口公网IP --------------------------------------------------------
get_wan_ip() {
  local ip=""
  ip="$(curl -fsSL --connect-timeout 8 --max-time 15 "http://ip-api.com/line?fields=query" 2>/dev/null | tr -d '\r' || true)"
  if [ -z "$ip" ] || ! echo "$ip" | grep -qE '^[0-9]+(\.[0-9]+){3}$'; then
    ip="$(curl -fsSL --connect-timeout 8 --max-time 15 "https://api.ipify.org" 2>/dev/null | tr -d '\r' || true)"
  fi
  [ -n "$ip" ] && echo "$ip" || true
}
 
# ---- 域名解析 -------------------------------------------------------------
resolve_domain() {
  local domain="$1" ips=""
  if command -v getent >/dev/null 2>&1; then
    ips="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u)"
  fi
  if [ -z "$ips" ] && command -v nslookup >/dev/null 2>&1; then
    ips="$(nslookup "$domain" 2>/dev/null | awk '/^Address:/{print $2}' | grep -v '#' | sort -u)"
  fi
  [ -n "$ips" ] && echo "$ips" || true
}
 
# ---- 获取最新 Release 信息 -------------------------------------------------
fetch_latest_json() {
  local url="$API_LATEST" json
  [ -n "$MIRROR" ] && url="${MIRROR}${url}"
  json="$(curl -fsSL --connect-timeout 12 --max-time 30 "$url" 2>/dev/null || true)"
  if [ -z "$json" ]; then
    echo "[错误] 无法访问 GitHub API: $url" >&2
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
  elif command -v python3 >/dev/null 2>&1; then
    echo "$json" | python3 -c 'import sys,json
try:
  d=json.load(sys.stdin); a=sys.argv[1]
  print(next((x["digest"] for x in d["assets"] if x["name"]==a), "").replace("sha256:",""))
except Exception: pass' "$asset"
  fi
}
 
# ---- 主流程 ---------------------------------------------------------------
echo "=================================================="
echo " RustDesk Server 无人值守安装 v2 (自包含部署)"
echo "=================================================="
 
read -r UNAME_ARCH ASSET_ARCH <<< "$(detect_plan)"
ARCH="$ARCH_OPT"
if [ -z "$ARCH" ]; then
  case "$UNAME_ARCH" in
    x86_64)  ARCH="amd64" ;;
    aarch64) ARCH="arm64" ;;
    armv7l)  ARCH="armv7" ;;
    unsupported)
      echo "[错误] 不支持的架构: $(uname -m), 仅支持 amd64/arm64/armv7" >&2
      exit 1 ;;
  esac
fi
 
# 架构 -> 官方资产名 (允许用户 --arch 覆盖)
case "$ARCH" in
  amd64) ASSET="rustdesk-server-linux-amd64.zip" ;;
  arm64) ASSET="rustdesk-server-linux-arm64v8.zip" ;;
  armv7) ASSET="rustdesk-server-linux-armv7.zip" ;;
  *) echo "[错误] 无效架构: $ARCH (仅支持 amd64/arm64/armv7)" >&2; exit 1 ;;
esac
 
# 已安装检测
if [ -f "$INSTALL_DIR/hbbs" ] && [ -f "$INSTALL_DIR/hbbr" ] && [ "$OVERWRITE" != "1" ]; then
  echo "[错误] 检测到 $INSTALL_DIR 已安装 RustDesk 服务端。" >&2
  echo "       如需覆盖重装请加 --overwrite=yes; 如不想动现有环境请勿运行本脚本。" >&2
  exit 1
fi
 
# 确定 ID 服务器地址
ID_ADDR=""
case "$MODE" in
  public)
    ID_ADDR="$(get_wan_ip)" || true
    if [ -z "$ID_ADDR" ]; then
      echo "[错误] 无法获取公网IP (ip-api.com 与 ipify 均失败)。" >&2
      echo "       请改用 --mode lan --ip <公网IP或域名>" >&2
      exit 1
    fi
    ;;
  domain)
    IPS="$(resolve_domain "$HOST")" || true
    if [ -z "$IPS" ]; then
      echo "[警告] 域名解析失败: $HOST, 自动回退到公网IP/内网IP模式" >&2
      ID_ADDR="$(get_wan_ip)" || true
      DEPLOY_BACK="公网IP"
      if [ -z "$ID_ADDR" ]; then
        ID_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
        DEPLOY_BACK="内网IP"
      fi
      if [ -z "$ID_ADDR" ]; then
        echo "[错误] 域名解析失败, 且无法自动获取公网/内网IP。" >&2
        echo "       请先确认域名 DNS 已生效, 或改用: --mode lan --ip <IP>" >&2
        exit 1
      fi
      echo "[信息] 已回退到 $DEPLOY_BACK 模式, ID 地址: $ID_ADDR" >&2
    else
      ID_ADDR="$HOST"
      WAN="$(get_wan_ip)" || true
      if [ -n "$WAN" ] && ! echo "$IPS" | grep -qx "$WAN"; then
        echo "[警告] 域名解析IP与本地出口IP($WAN)不一致, 无人值守模式自动继续; 请确认 DDNS 生效" >&2
      fi
    fi
    ;;
  lan)
    ID_ADDR="$HOST"
    ;;
esac
 
if [ "$DRY_RUN" = "1" ]; then
  echo "==> 预检模式, 不执行任何下载与安装"
  echo "==> 目标架构   : $ARCH (资产: $ASSET)"
  echo "==> 部署方式   : $MODE"
  echo "==> ID 服务器  : $ID_ADDR"
  [ -n "$TAG_OPT" ] && echo "==> 固定版本   : $TAG_OPT"
  [ -n "$MIRROR" ] && echo "==> 下载镜像   : $MIRROR"
  echo "==> 覆盖重装   : $([ "$OVERWRITE" = "1" ] && echo yes || echo no)"
  echo "==> 安装目录   : $INSTALL_DIR / 日志目录: $LOG_DIR"
  echo "==> 预检完成, 无问题。"
  exit 0
fi
 
# ---- root 权限检查(仅真实安装前) -------------------------------------------
if [ "$(id -u)" -ne 0 ]; then
  echo "[错误] 请以 root 权限运行: sudo bash $(basename "$0")" >&2
  exit 1
fi
 
# ---- 获取版本 -------------------------------------------------------------
JSON_LATEST=""
TAG="$TAG_OPT"
if [ -z "$TAG" ]; then
  echo "==> 正在获取最新 Release ..."
  JSON_LATEST="$(fetch_latest_json)"
  TAG="$(parse_tag "$JSON_LATEST")"
fi
echo "==> rustdesk-server 版本: $TAG"
 
# ---- 下载 ----------------------------------------------------------------
URL="${RELEASE_ROOT}/${TAG}/${ASSET}"
[ -n "$MIRROR" ] && URL="${MIRROR}${URL}"
mkdir -p "$WORK_DIR"
ZIP="${WORK_DIR}/${ASSET}"
 
echo "==> 下载: $URL"
curl -fSL --retry 3 --connect-timeout 15 --max-time 600 -o "$ZIP" "$URL"
echo "==> 下载完成: $ZIP ($(du -h "$ZIP" 2>/dev/null | cut -f1))"
 
# ---- sha256 校验 ----------------------------------------------------------
if [ -n "$JSON_LATEST" ]; then
  EXPECTED="$(parse_digest "$JSON_LATEST" "$ASSET")"
  if [ -n "$EXPECTED" ] && command -v sha256sum >/dev/null 2>&1; then
    ACTUAL="$(sha256sum "$ZIP" | awk '{print $1}')"
    if [ "$ACTUAL" != "$EXPECTED" ]; then
      echo "[错误] sha256 校验失败, 文件可能损坏或镜像异常" >&2
      rm -f "$ZIP"
      exit 1
    fi
    echo "==> sha256 校验通过"
  else
    echo "[提示] 无法获取资产 sha256 (无 jq/python3/sha256sum), 跳过校验"
  fi
fi
 
# ---- 部署 ----------------------------------------------------------------
mkdir -p "$INSTALL_DIR" "$LOG_DIR"
 
# 解压
if command -v unzip >/dev/null 2>&1; then
  unzip -q -o "$ZIP" -d "$INSTALL_DIR"
else
  echo "[提示] 未找到 unzip, 尝试用 python3 解压"
  command -v python3 >/dev/null 2>&1 || { echo "[错误] 缺少 unzip 或 python3, 无法解压" >&2; exit 1; }
  python3 -c "import zipfile,sys; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])" "$ZIP" "$INSTALL_DIR"
fi
 
# 将 hbbs/hbbr 移动到安装目录根 (官方 zip 内为 amd64/ 等子目录)
HBBS_SRC="$(find "$INSTALL_DIR" -type f -name hbbs | head -1 || true)"
HBBR_SRC="$(find "$INSTALL_DIR" -type f -name hbbr | head -1 || true)"
if [ -z "$HBBS_SRC" ] || [ -z "$HBBR_SRC" ]; then
  echo "[错误] 组件包内未找到 hbbs/hbbr" >&2
  exit 1
fi
[ "$HBBS_SRC" != "$INSTALL_DIR/hbbs" ] && mv -f "$HBBS_SRC" "$INSTALL_DIR/hbbs"
[ "$HBBR_SRC" != "$INSTALL_DIR/hbbr" ] && mv -f "$HBBR_SRC" "$INSTALL_DIR/hbbr"
chmod +x "$INSTALL_DIR/hbbs" "$INSTALL_DIR/hbbr"
rm -f "$ZIP"
 
# 启动服务
if command -v systemctl >/dev/null 2>&1; then
  echo "==> 配置并启动 systemd 服务 (hbbs:${HBS_PORT} / hbbr:${HBR_PORT})"
  cat > "$SYSTEMD_DIR/rustdesksignal.service" <<EOF
[Unit]
Description=RustDesk Signal Server
After=network.target
[Service]
Type=simple
ExecStart=$INSTALL_DIR/hbbs -p $HBS_PORT -r $ID_ADDR:$HBR_PORT
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/signal.log
StandardError=append:$LOG_DIR/signal.error
[Install]
WantedBy=multi-user.target
EOF
  cat > "$SYSTEMD_DIR/rustdeskrelay.service" <<EOF
[Unit]
Description=RustDesk Relay Server
After=network.target
[Service]
Type=simple
ExecStart=$INSTALL_DIR/hbbr -p $HBR_PORT
WorkingDirectory=$INSTALL_DIR
Restart=always
RestartSec=10
StandardOutput=append:$LOG_DIR/relay.log
StandardError=append:$LOG_DIR/relay.error
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now rustdesksignal.service rustdeskrelay.service
else
  echo "==> 未检测到 systemd, 以后台进程方式启动"
  nohup "$INSTALL_DIR/hbbs" -p "$HBS_PORT" -r "$ID_ADDR:$HBR_PORT" >> "$LOG_DIR/signal.log" 2>&1 &
  nohup "$INSTALL_DIR/hbbr" -p "$HBR_PORT" >> "$LOG_DIR/relay.log" 2>&1 &
fi
 
# 等待密钥生成并输出结果
sleep 2
PUB_KEY=""
if [ -f "$INSTALL_DIR/id_ed25519.pub" ]; then
  PUB_KEY="$(tr -d '\r\n' < "$INSTALL_DIR/id_ed25519.pub")"
else
  PUB_KEY="$(find "$INSTALL_DIR" -name '*.pub' -type f 2>/dev/null | head -1 | xargs -r cat 2>/dev/null | tr -d '\r\n')"
fi
 
echo "=================================================="
echo " 安装完成!"
echo " ID服务器地址   : $ID_ADDR"
echo " 中继服务器地址 : $ID_ADDR"
echo " Key            : ${PUB_KEY:-未能读取, 请稍后查看 $INSTALL_DIR/id_ed25519.pub}"
echo " 日志目录       : $LOG_DIR"
echo " 启动/停止命令  : systemctl start/stop rustdesksignal rustdeskrelay"
echo "=================================================="
