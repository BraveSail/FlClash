# plan: 内核自持 profile 通道（拉取 + 推送 + 热重载）

## 问题

mesh 展开已在内核（`config/mesh.go:149`，由 `config/config.go:636` 调用），但**拿配置的通道不在内核**：

- 内核只读 `-f` 指定的那一个本地文件，启动后不再变（`grep -rn '/profile' --include=*.go` → 空）
- 拉取 + WebSocket 推送只存在于 **FlClash(Dart)**：`lib/providers/actions/profiles.dart:104` 连 `/profile/watch`，`lib/common/hub.dart:33` 拼 URL
- 后果：**跑裸内核的设备（光猫）拿不到任何下发**。`GET /profile?id=ont` → **404**，从没下发过

所以"hub 推送推不了"不是 hub 的问题，是**接收端只存在于 app 里**。

## 目标（Phase 1 Contract）

**要改变：**

1. 内核自己能拉配置：按 id 从 hub 取 YAML，落盘，热重载
2. 内核自己能收推送：持有 `/profile/watch` socket，收到新 YAML 立即热重载
3. 断线重连 + 轮询兜底（socket 是加速通道，轮询是保证）
4. 光猫改用它，不再依赖手工 `-f` 文件

**必须不变（可被命令证伪）：**

- 不带 profile 配置时，`-f` 单文件行为**完全不变**（现有部署不回归）
- mesh 的派生/上报/监听语义不变：`go test ./config/ ./adapter/` 全绿
- 光猫默认配置（`MATCH,DIRECT`、无 TUN、`allow-lan: false`、不对 LAN 开控制器）**不受影响**
- 凭据不进源码（`BraveSail/FlClash` 是 public fork）
- 光猫暴露面不扩大：不新增对外监听端口

## Phase 2 — 设计决策

### 决策 1：通道放内核（而不是给光猫塞一个 Dart 客户端）

**选**：在内核里实现。

**否掉的替代**：在光猫上跑一个拉取脚本（`wget` + `cron`）+ `kill -HUP`。理由：光猫的 `wget` **HTTPS 是坏的**（`ssl_helper: No such file`）、没有 curl/openssl/python；用 shell 拼 WebSocket 客户端不现实，而重载还得靠信号，链路脆。

**理由**：内核已经有 `http.Client` + mihomo 自己的 `dialer`（`peer_directory.go:161`、`directoryTransport()` at `:178`），TLS、CA、直连/代理二选一全都现成。一处实现，**所有跑内核的设备都受益**（光猫、将来的路由、PC 的 core）。

### 决策 2：WebSocket 用现成依赖，不手搓

**选**：内核里已有 `transport/vmess/websocket.go`，优先复用它依赖的 ws 库；没有就加一个成熟库（`gorilla/websocket`）。

**否掉的替代**：长轮询 only。理由：推送是"改了立刻生效"的体验，长轮询有延迟且更费连接。但**轮询作为兜底保留**（决策 3）。

### 决策 3：推送 + 轮询双通道

socket 断开期间靠轮询（带 ETag，未变返回 304，成本极低）。两者都调同一个"发现新 YAML → 热重载"的函数，不写两遍。

### 决策 4：热重载复用 `executor.ApplyConfig`

**选**：`hub/route/configs.go:438` 已经在用 `executor.ApplyConfig(cfg, force)`。拉取到新 YAML 后走同一条路：解析 → 比对 → apply。

### 决策 5：光猫的配置由谁生成

**选**：hub 上按 `id=ont` 存一份光猫版 profile（TUN off、无 LAN 控制器、`directory-id: ont` 写死）。生成脚本已写好并校验通过。

**否掉的替代**：光猫直接用 PC 那份。理由：那份 `tun.enable: true`（光猫无 `/dev/net/tun`）、`allow-lan: true`、`external-controller: 0.0.0.0:9090`（扩大暴露面）、`directory-id` 为空（光猫无 `/etc/machine-id`，算不出来）。

## Phase 3 — 实现

1. **内核**：新增 profile 客户端
   - 配置项：`profile-url` / `profile-id` / `profile-token`（或在 `mesh:` 旁加 `hub:` 块）
   - 拉取：`GET {url}/profile?id={id}`，带 `Authorization: Bearer {token}` + `If-None-Match`
   - 落盘到 `{home}/profile.yaml`，然后热重载
   - WebSocket：`{wsurl}/profile/watch?id=&etag=`，收到即重载
   - 重连退避 + 轮询间隔（都带 ETag）
2. **光猫**：`/opt/info/ont-mesh2.yaml` 改为指向 profile 通道，或由内核自动拉
3. **FlClash**：Dart 侧通道保留（app 有 app 的场景），但不再**只有**它有

## Phase 4 — 验证

- 内核单测：拉取 + 304 + 重载 + socket 重连
- 真实执行：PC 上用 CLI 内核加载 + 拉 hub profile
- 变异验证：去掉修复，确认测试失败
- **端到端**：hub 面板改 YAML → 光猫在 N 秒内生效（不改文件、不重启进程）
- 身份核对：`go version -m` 确认部署的二进制是新的

## Phase 5 — 集成

- Clash.Meta 子模块提交 → 推 → 主仓 gitlink 更新 → CI
- 光猫：部署新内核 + 切换配置

## Phase 6 — 收尾

- 从外部确认（改 hub 上 YAML，观察光猫行为变化）
- 保留回滚：备份原 `ont-mesh2.yaml` + 原内核
- 分开报告"已验证"与"未验证"

## 风险 / 待定

**已排除：**

- ~~ws 依赖~~ → **`github.com/gobwas/ws v1.4.0` 已在 `go.mod`**（第 10 行），无需新增依赖
- ~~凭据用哪个~~ → **是同一个**：hub 的 `checkAuth` 只认一个 Bearer token，`/report`、`/profile`、`/profile/watch` 共用（`hub.dart:72 hubAuthHeaders` 与 mesh 的 `directory-token` 同源）。光猫现配置里就有
- ~~配置格式~~ → `mihomo -t` 校验光猫版配置**通过**（`test is successful`）
- ~~热重载~~ → `executor.ApplyConfig(cfg, force)` 现成（`hub/route/configs.go:438`）

**仍在：**

- **光猫空间**：`/opt/info` 只剩 **5.2MB**（88% 已用），新内核 37MB 必须就地覆盖
- **光猫能力**：无 TUN、无 `/dev/net/tun`；CPU 无 AES（ChaCha）；`wget` 的 HTTPS 是坏的（`ssl_helper` 缺失）——所以拉取必须由内核做，不能靠 shell
- 内核 `profile/watch` 的重连语义需与 hub 的 `delivered` 计数对齐（未连上的设备靠轮询补）
