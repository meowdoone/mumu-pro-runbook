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

`--check` 会执行 `settings put global http_proxy :0` 清设备代理，脚本跑完自动恢复。

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

## 文件

- `mumu.sh` —— 全部操作入口，`./mumu.sh` 不带参数看用法
- `rotating_proxy.py` —— 本地免认证转发器，每连接自动在代理池里换节点
- 代理列表：`~/Desktop/iproyal-proxies.txt`（`host:port:user:pass`，一行一个）
- 上游项目：`~/Downloads/one-sku-study`（`pro0.py` 等，本脚本只是包一层）
