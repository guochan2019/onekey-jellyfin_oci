# Jellyfin OCI CT 一键重建脚本（PVE）

在 PVE 9.1+ 宿主机上一键重建 OCI Jellyfin 容器（CT）：拉取最新 preview 镜像 → 创建特权容器 → 配置持久化 / 媒体库挂载 / GPU 直通 → 启动验证。

## 快速开始

在 PVE 宿主（root）上执行：

```bash
# 下载脚本
wget https://raw.githubusercontent.com/guochan2019/onekey-jellyfin_oci/main/onekey-jellyfin_oci.sh
# 运行（交互：容器 ID + root 密码 + IP/网关）
bash onekey-jellyfin_oci.sh
```

## 脚本流程

| 步骤 | 说明 |
|------|------|
| ① 拉取 OCI 镜像 | 删除旧模板 → `skopeo copy` 拉取 `jellyfin/jellyfin:preview`（重建 = 取最新版本） |
| ② 创建容器 | 交互选择容器 ID（默认 200）、root 密码（不回显）、IP/网关；已存在则确认销毁重建；以 unprivileged 创建 |
| ③ 配置容器 | 删除 `unprivileged: 1` 转特权、`cmode: shell`、onboot/startup、`/dev/dri` GPU 直通、features（fuse + NFS/CIFS + nesting）、六个挂载点（/config /cache + 4 个媒体目录） |
| ④ 启动验证 | 启动容器，验证 PID1=jellyfin、`:8096/health` 返回 200、挂载点容器内可见 |

## 参数说明（脚本顶部变量，按需修改）

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `CTID` | 200（运行时交互可改） | 容器 ID |
| `CT_NAME` | Jellyfin-Films | 容器名称 |
| `CT_PASS` | 运行时交互输入（不回显） | 容器 root 密码 |
| `CT_IP` | 运行时交互输入（默认值见脚本） | 容器 IPv4（CIDR） |
| `CT_GW` | 运行时交互输入（默认值见脚本） | 默认网关 |
| `TPL_REF` | `docker://jellyfin/jellyfin:preview` | OCI 镜像（skopeo 源，需 `docker://` 前缀） |
| `ROOTFS` | `local:8` | 根磁盘（8 GB） |
| `DATA_DIR` | `/opt/jellyfin` | 配置/缓存目录（宿主侧，内含 config/cache） |
| `NVME_UUID` | 按宿主实际设备修改 | mp5 整盘直通的 NVMe 磁盘 UUID |

## 注意事项

1. **PVE 9.x OCI 特权创建已知 bug**：`--unprivileged 0` 创建必失败（`setgid(0): Invalid argument`，官方确认）。脚本先以 unprivileged 创建成功，再删除 conf 中的 `unprivileged: 1` 转为特权容器。
2. **`--cmode shell` 在 OCI 创建流程不写入 conf**，脚本用 `pct set` 显式设置。
3. **`/opt/jellyfin/config`、`/opt/jellyfin/cache` 存在即保留**：Jellyfin 配置/缓存持久化，重建容器不丢失（不存在则自动创建）。
4. **GPU 硬件转码**：宿主需有 Intel/AMD 核显（`/dev/dri/card0` + `renderD128` 直通，mode=0777）。Jellyfin 后台 → 播放 → 转码 → 硬件加速选 VAAPI。
5. **媒体挂载依赖宿主已有目录/设备**：`/mnt/pve/films4k`、`/mnt/pve/films2k`（PVE 存储挂载）、`/mnt/pve/clouddrive/CloudDrive`（CloudDrive2 fuse 挂载，需 CD2 运行中）、NVMe 整盘（`/dev/disk/by-uuid/<NVME_UUID>`，脚本顶部按实际 UUID 修改）。
6. **IPv6 不配置**（net0 留空）；DNS 不设置；MAC 由 PVE 随机生成。

## 验证

```bash
pct exec <CTID> -- cat /proc/1/comm          # 应输出 jellyfin（entrypoint 自动生效）
pct exec <CTID> -- curl -s -o /dev/null -w "%{http_code}" http://localhost:8096/health   # 应输出 200
pct exec <CTID> -- ls -d /config /cache /mnt/films4k /mnt/films2k /mnt/clouddrive /mnt/nvme1
```

首次初始化：浏览器打开 `http://<CT-IP>:8096`（Jellyfin Web 管理界面，设置管理员账号 + 添加媒体库，媒体目录见上方挂载点）。
