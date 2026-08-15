#!/bin/bash
# ============================================================
# onekey-jellyfin_oci — PVE 一键重建 OCI Jellyfin CT（Jellyfin-Films）
# 适用环境: PVE 9.1+（OCI 支持），宿主 root 运行
# 功能: 拉 OCI 镜像 → 建特权 CT → 配置持久化/媒体挂载/GPU 直通 → 启动验证
# ============================================================
set -e

# ---------- 彩色输出 ----------
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'
info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
err()   { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# ---------- 检测 root ----------
if [ "$(id -u)" -ne 0 ]; then
  err "请以 root 用户运行 (当前非 root)"
fi

# ---------- 检测 PVE 环境 ----------
command -v pct &>/dev/null || err "未找到 pct，请确认在 PVE 宿主上运行"
command -v pveam &>/dev/null || err "未找到 pveam"
command -v skopeo &>/dev/null || err "未找到 skopeo（PVE 9.1+ OCI 支持依赖）"

# ---------- 配置 ----------
CTID=200
CT_NAME="OCI-Jellyfin"
CT_IP="192.168.50.11/24"
CT_GW="192.168.50.2"
TPL_REF="docker://jellyfin/jellyfin:preview"
TPL_NAME="jellyfin_preview.tar"
VZTPL_DIR="/var/lib/vz/template/cache"
ROOTFS="local:8"
DATA_DIR="/opt/jellyfin"
NVME_UUID="5d4ab423-0e1a-45aa-b209-435e28fde989"

# ---------- 检测 local 存储模板目录 ----------
if [ ! -d "${VZTPL_DIR}" ]; then
  VZTPL_DIR=$(pveam list local 2>/dev/null | awk 'NR==2{print $2}' | sed 's|local:vztmpl/.*||')
  [ -n "${VZTPL_DIR}" ] || err "无法定位 vztmpl 目录，请检查 local 存储配置"
  VZTPL_DIR="${VZTPL_DIR}/vztmpl"
fi

# =================== ① 拉镜像 ===================
info "=== 1/4 拉取 OCI 镜像 ==="
# 重建目的为获取最新版本：模板存在则删除后重新拉取
if [ -f "${VZTPL_DIR}/${TPL_NAME}" ]; then
  info "  删除旧模板 ${TPL_NAME}（重建=拉取最新）"
  pveam remove "local:vztmpl/${TPL_NAME}"
fi
info "  拉取 ${TPL_REF} → ${VZTPL_DIR}/${TPL_NAME}"
skopeo copy "${TPL_REF}" "oci-archive:${VZTPL_DIR}/${TPL_NAME}"
info "  ✓ 模板拉取完成"

# =================== ② 建 CT ===================
info "=== 2/4 创建容器 ==="

# 选择容器 ID
read -p "请输入容器 ID (默认 200): " CTID_INPUT </dev/tty
CTID=${CTID_INPUT:-200}
CONF="/etc/pve/lxc/${CTID}.conf"
info "  容器 ID: ${CTID}"

# 输入 root 密码（不回显）
read -s -p "请输入容器 root 密码: " CT_PASS </dev/tty
echo ""
[ -n "${CT_PASS}" ] || err "密码不能为空"
info "  ✓ root 密码已设置（不回显）"

# 容器 IP / 网关（默认 192.168.50.11/24、192.168.50.2）
read -p "请输入容器 IP (默认 ${CT_IP}): " CT_IP_INPUT </dev/tty
CT_IP=${CT_IP_INPUT:-${CT_IP}}
read -p "请输入网关 IP (默认 ${CT_GW}): " CT_GW_INPUT </dev/tty
CT_GW=${CT_GW_INPUT:-${CT_GW}}
info "  容器 IP: ${CT_IP}（网关 ${CT_GW}）"

if pct status ${CTID} &>/dev/null; then
  warn "CT ${CTID} (${CT_NAME}) 已存在！"
  read -p "确认销毁并重建？(y/n，默认 n): " REBUILD </dev/tty
  if [ "${REBUILD:-n}" != "y" ] && [ "${REBUILD:-n}" != "Y" ]; then
    err "已取消，请手动处理 CT ${CTID}"
  fi
  pct stop ${CTID} 2>/dev/null || true
  pct destroy ${CTID} --purge
  info "  ✓ 旧 CT ${CTID} 已销毁"
fi

# 配置目录（/config /cache 状态持久化，宿主侧；不存在才新建，存在即跳过保留）
for dir in "${DATA_DIR}/config" "${DATA_DIR}/cache"; do
  if [ -d "${dir}" ]; then
    info "  ${dir} 已存在，跳过（保留）"
  else
    mkdir -p "${dir}"
    info "  已创建 ${dir}"
  fi
done

# 以 unprivileged 创建（PVE 9.x OCI 特权创建是已知 bug，③ 再删行转特权）
pct create ${CTID} "local:vztmpl/${TPL_NAME}" \
  --hostname "${CT_NAME}" --password "${CT_PASS}" \
  --rootfs "${ROOTFS}" --cores 2 --memory 2048 --swap 1024 \
  --net0 name=eth0,bridge=lan0,ip=${CT_IP},gw=${CT_GW},firewall=0 \
  --unprivileged 1 --cmode shell --start 0
info "  ✓ CT ${CTID} 已创建"

# =================== ③ 配置 ===================
info "=== 3/4 配置容器 ==="

# 删除 unprivileged: 1（新建完成后转特权——PVE 9.x OCI 特权创建是已知 bug，
# 必须先以 unprivileged 建成，再删除该行转为特权容器）
sed -i '/^unprivileged: 1$/d' "${CONF}"
info "  ✓ 已删除 unprivileged: 1（转为特权容器）"

# 控制台模式 shell（OCI 创建流程未写入，需显式设置）
pct set ${CTID} --cmode shell
info "  ✓ 控制台模式已设为 shell"

# 开机自启 + 启动顺序
pct set ${CTID} --onboot 1 --startup order=5,up=10
info "  ✓ 已设置 onboot=1、startup order=5,up=10"

# GPU 直通（硬件转码：VAAPI/QSV 用 renderD128）
pct set ${CTID} --dev0 /dev/dri/card0,mode=0777
pct set ${CTID} --dev1 /dev/dri/renderD128,mode=0777
info "  ✓ GPU 直通: /dev/dri/card0、/dev/dri/renderD128 (mode=0777)"

# features: fuse + NFS/CIFS 挂载 + nesting（值含分号，必须加引号）
pct set ${CTID} --features "fuse=1,mount=nfs;cifs,nesting=1"
info "  ✓ features: fuse=1,mount=nfs;cifs,nesting=1"

# 挂载点：config/cache 持久化 + 4 个媒体库 + NVMe 整盘
pct set ${CTID} --mp0 "${DATA_DIR}/config,mp=/config"
pct set ${CTID} --mp1 "${DATA_DIR}/cache,mp=/cache"
pct set ${CTID} --mp2 /mnt/pve/films4k,mp=/mnt/films4k
pct set ${CTID} --mp3 /mnt/pve/films2k,mp=/mnt/films2k
pct set ${CTID} --mp4 /mnt/pve/clouddrive/CloudDrive,mp=/mnt/clouddrive
pct set ${CTID} --mp5 "/dev/disk/by-uuid/${NVME_UUID},mp=/mnt/nvme1"
info "  ✓ 挂载点已配置: /config /cache /mnt/films4k /mnt/films2k /mnt/clouddrive /mnt/nvme1"

# =================== ④ 启动 + 验证 ===================
info "=== 4/4 启动并验证 ==="

pct start ${CTID}
info "  ✓ CT ${CTID} 已启动"

# 等容器就绪
for i in $(seq 1 30); do
  pct exec ${CTID} -- true 2>/dev/null && break
  sleep 1
done

# PID1 应为 jellyfin（OCI entrypoint 自动生效，与 tailscale containerboot 同理）
PROC1=$(pct exec ${CTID} -- cat /proc/1/comm 2>/dev/null || echo "?")
info "  容器 PID1 进程: ${PROC1}"

# 等 Jellyfin Web 就绪（/health 返回 200，最长 120 秒）
for i in $(seq 1 60); do
  CODE=$(pct exec ${CTID} -- curl -s -o /dev/null -w "%{http_code}" --max-time 5 http://localhost:8096/health 2>/dev/null || echo "000")
  if [ "${CODE}" = "200" ]; then
    break
  fi
  sleep 2
done
info "  Jellyfin /health 状态码: ${CODE}"

# 验证全部挂载点容器内可见（任一缺失即报错停止）
pct exec ${CTID} -- ls -d /config /cache /mnt/films4k /mnt/films2k /mnt/clouddrive /mnt/nvme1 >/dev/null
info "  ✓ 全部挂载点容器内可见"

# =================== 完成 ===================
echo ""
info "========== 配置信息汇总 =========="
info "  CT ID        : ${CTID}"
info "  容器名称     : ${CT_NAME}"
info "  容器 IP      : ${CT_IP}（网关 ${CT_GW}）"
info "  Web 管理界面 : http://${CT_IP%%/*}:8096"
info "  配置目录     : ${DATA_DIR}/config → /config、${DATA_DIR}/cache → /cache"
info "  媒体挂载     : /mnt/films4k /mnt/films2k /mnt/clouddrive /mnt/nvme1"
info "  GPU 直通     : /dev/dri/card0 + /dev/dri/renderD128（VAAPI 硬件转码）"
echo ""
info "=== 下一步 ==="
info "  浏览器打开 http://${CT_IP%%/*}:8096 完成首次初始化（管理员账号 + 添加媒体库）"
info "  硬件转码开启: 后台 → 播放 → 转码 → 硬件加速选 VAAPI，设备 /dev/dri/renderD128"
info "  容器内媒体目录: /mnt/films4k /mnt/films2k /mnt/clouddrive /mnt/nvme1"
