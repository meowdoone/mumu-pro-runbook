# MuMu Pro 跑号环境 runbook

在 Mac + MuMu Pro 上跑 Google One 免费 Pro 的稳定化封装。**按顺序做，别跳步。**

来源：2026-11-24 实操，每一步都是踩过坑之后定下来的。

---

## 0. 一次性准备

```bash
pip3 install --user --break-system-packages frida==16.7.19   # 用 python3.12
```

- 本机 `/usr/bin/python3` 是 3.9，`pro0.py` 用了 `dict | None` 语法，**3.9 跑不了**。固定用 `~/.local/bin/python3.12`。
- frida 必须 16.x。17.x 删了 Java bridge，全部失效。

## 1. 开机

```bash
./mumu.sh boot
```

## 2. 换 IP

```bash
./mumu.sh proxy up      # 起本地轮换转发器（失败自动换节点）
./mumu.sh proxy ip      # 确认出口 IP
./mumu.sh net on        # 设备代理 → 10.0.2.2:18790
```

**为什么不能直接把 IPRoyal 填进设备代理**：Android 全局 `http_proxy` 不支持 `user:pass@host`，
GMS 登录会直接 `ERR_TUNNEL_CONNECTION_FAILED` + HTTP 407。必须本地免认证转发。

## 3. 起 Play（顺序关键）

```bash
./mumu.sh play          # 内部先 pkill frida，再拉 Play
./mumu.sh frida on      # Play 起来之后才起 frida
```

**frida-server 先跑 = Play 必挂**：进程 fork 后 50 秒 attach 超时被杀，表现为白屏/打不开。

## 4. 自检

```bash
./mumu.sh check
```

`--check` 内部有坑：它会先把 frida 起起来、又会把设备代理清成 `:0`。所以 `./mumu.sh check` 不直接跑它，而是自己按「代理 → Play → frida → 检查 → 恢复代理」的顺序走，最后才调 pro0.py 校验。

## 5. 跑号

```bash
./mumu.sh run-18m
```

## 6. 换号 = 重置

```bash
./mumu.sh reset         # 备份旧盘 → 换新盘 → 等开机
```

重置会丢掉 `/data/local/tmp` 里的 frida-server 和计费模块（下次 `check` 重推），
但 ROOT/ADB 是模拟器层设置，不丢。

办完换号后从第 2 步重来（**必须换 IP**，同 IP 连着跑同一批号容易被要求验证）。

---

## 已知坑

| 现象 | 根因 | 处理 |
|---|---|---|
| Play 白屏打不开 | frida-server 先于 Play 存在 | `./mumu.sh play` 再 `frida on` |
| 登录 "Something went wrong" | 代理 407（全局代理不认账密） | `./mumu.sh proxy up` + `net on` |
| 代理时通时不通 | IPRoyal 节点随机 403 | rotating_proxy.py 每次连接自动换节点（脚本已内置） |
| `unsupported operand type(s) for \|` | 用了 python 3.9 | 换 python3.12 |
| ADB 连不上 | 端口每次重启都变 | 不要写死，用 `./mumu.sh serial` |
| 设备没 root | 模拟器 ROOT 被关 | `mumu-cli config 0 --setting '{"vmRootEnable":true}'` 后重启 |
| **Google One 装不上 / 查 SKU 全空** | **账号的 Play 国家是 CN**（`account-play-country`，服务端判定） | 见下节 |

## 地区（country）是最容易卡住的一点

Play 的账号国家记在 `shared_prefs/finsky.xml` 的 `account-play-country`。**以服务端为准**：
本地 `sed` 改 `CN`→`US` 会被服务器在下次启动时覆盖回去，单改无效。

- 换 IP 不改国家（IP 只影响能不能连，不影响账号归属）
- 改系统语言 en-US 也只是第二顺位，改了 Play 仍判 CN
- Play 判定为 CN 时：`market://` 打 Google One 页显示 "isn't available in your country"，
  `query_sku.py` 返回空

三条出路：
1. **Google One 直接侧载**（本机已做，见下）——绕过商店，但 App 内仍会说
   "isn't available for this account"
2. 用 Play 的「切换国家」流程：需要在**目标国 IP** 下、且账号有该国付款方式，
   一年只能改一次
3. 换一个本身注册在 US 的号

### 侧载 Google One

商店装不上时（地区被挡），直接拿 XAPK 装：

```bash
curl -sL -x http://127.0.0.1:18790 -A "Mozilla/5.0" \
  -o /tmp/go.xapk \
  "https://d.apkpure.net/b/APK/com.google.android.apps.subscriptions.red?version=latest"
```

解开后取 `*.apk` + `config.arm64_v8a.apk` + `config.en.apk` + `config.mdpi.apk`，
用 `pm install-create / install-write / install-commit` 装（分包，`adb install` 单个装不了）。
`https://d.apkpure.net` 可用；`d.apkpure.com` 和 `apkpure.net` 会被 Cloudflare 拦。

## 文件

- `mumu.sh` —— 全部操作入口，`./mumu.sh` 不带参数看用法
- `rotating_proxy.py` —— 本地免认证转发器，每连接自动在代理池里换节点
- 代理列表：`~/Desktop/iproyal-proxies.txt`（`host:port:user:pass`，一行一个）
- 上游项目：`~/Downloads/one-sku-study`（`pro0.py` 等，本脚本只是包一层）
