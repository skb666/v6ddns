# v6-ddns — 家宽 IPv6 动态域名 + 自动续期证书

给「路由器后面、家宽 IPv6 直连」的场景做的**一条龙部署**。不需要公网 IPv4。
本文对应 **`cloudflare` 分支**，只支持 Cloudflare；`main` 不受本分支改动影响。

解决的问题：家宽的 IPv6 前缀会变（电信重拨、路由器重启都会换），静态
DNS 记录迟早指向一个你不拥有的地址，公网就再也连不上了。这套东西负责
「盯着地址 → 变了就更新 AAAA → 证书自动续期」。

---

## 快速开始

```bash
git switch cloudflare
sudo apt install -y certbot python3-certbot-nginx     # 首次需要
# nginx 模式先按下方「nginx TLS 配套文件」步骤补齐本机包资源
# 首次申请前注册 ACME 账号；先阅读服务条款，将邮箱替换为自己的
sudo certbot register --agree-tos --email you@example.com
sudo ./v6-ddns-install.sh \
    --domain example.com \
    --zone-id '0123456789abcdef0123456789abcdef' \
    --token '你的Cloudflare_API_Token' \
    --issue-cert
```

Zone ID 从 Cloudflare 控制台目标域名的概述页复制，Token 用 API Token，
不是 Global API Key，也不是旧平台的 `AK,SK`。Token 只需要目标 zone 的
**Zone / DNS / Edit**，不需要 Zone Read，详见 [Cloudflare 配置](#cloudflare-配置)。

也可通过 `V6DDNS_ZONE_ID` / `V6DDNS_TOKEN` 传入（使用 sudo 时需显式保留相应环境变量）；
命令行参数优先。命令行 Token 可能进入 shell 历史和进程参数，避免共享终端上直接填写真实值。
省略凭据仅能沿用 `/etc/v6-ddns/env` 中**同域名且完整有效的 Cloudflare 配置**；
省略 `--host` 时沿用原 host，显式 host 不匹配会失败，不会静默忽略。
同域重装即使完整传入凭据也遵守这条 host 规则；轮换 Token/Zone ID 时保留
`V6DDNS_TTL`、`V6DDNS_IFACE` 等无关字段与注释。
迁移其他平台时必须显式提供新的 Zone ID 和 API Token，不能复用旧凭据。

**首次迁移后执行 `sudo /usr/local/bin/v6-ddns --force`**，强制核对并同步 Cloudflare
远端记录。共享状态 `/var/lib/v6-ddns/address` 会保留；如果本地地址没变，普通运行会
按旧 state 跳过远端更新。不要为迁移擅自删除 state；离线 dry-run 不替代这次同步。

部署完成后还剩两步必须手工做，见 [部署后](#部署后必须手工做的两件事)。

### 全部参数

| 参数 | 说明 |
|---|---|
| `--domain NAME` | 域名，**必填** |
| `--zone-id ID` | 32 位十六进制 Cloudflare Zone ID；也可用 `V6DDNS_ZONE_ID` |
| `--token TOKEN` | Cloudflare API Token；也可用 `V6DDNS_TOKEN`；省略仅沿用同域 Cloudflare 配置 |
| `--host LABEL` | 记录标签，默认 `@`（根域）。`home` → `home.example.com` |
| `--issue-cert` | 首次申请；已有同名 lineage 则 reconfigure 并核验续期参数；需要 Certbot >= 2.3 |
| `--no-nginx` | 跳过 nginx vhost、检查和 reload，不保存 nginx 续期 reload |
| `--dry-run` | 在 root/依赖检查和系统写入前校验并展示计划；不显示 Token，不调用 API/certbot |

---

## 前置条件

**必须满足：**

1. 运营商给了**公网 IPv6**，且路由器把前缀委派给了内网
2. 路由器 IPv6 出站正常（`ping -6 2400:3200:baba::1` 通）
3. 域名 NS 已按控制台提示指向 Cloudflare，zone 已激活（见 [Cloudflare 配置](#cloudflare-配置)）
4. 已取得目标 zone 的 Zone ID 和仅限该 zone 的 DNS Edit API Token

**主机依赖：**

```bash
sudo apt install -y certbot python3-certbot-nginx iproute2 python3
```

证书操作仅支持 **Certbot >= 2.3**，且必须支持 `reconfigure`；安装器会先检查。
首次申请前需按快速开始注册 ACME 账号。已有同名证书会通过 `reconfigure` 执行
staging 验证，成功后保存新的 manual/DNS-01 auth/cleanup，即使证书尚未到期也会保存；
不会为重装强制生产续期。首次申请显式使用 `--cert-name DOMAIN`，成功后核验同名
renewal 的证书路径与保存参数；路径不符就失败，不猜测 `DOMAIN-0001`。

`--no-nginx` 不会静默抹掉旧 lineage 的 `installer=nginx`。遇到这种旧配置会在写入前
失败并提示，需先用 Certbot 明确处理旧 installer 或使用满足 nginx 前提的模式。

### nginx TLS 配套文件

manual `certonly` 不负责初始化 nginx 插件的 TLS 配套文件。默认 nginx 模式要求
`/etc/letsencrypt/options-ssl-nginx.conf` 和 `ssl-dhparams.pem` 已存在且非空；
安装器会在写凭据、vhost 或系统文件前检查，缺失则失败。`--no-nginx` 免除此检查。

先安装发行版配套的 `certbot` / `python3-certbot-nginx`，确认使用的是同一套版本
（不要混用 apt 与 snap/pip 的 Certbot）。下面用发行版 `/usr/bin/python3` 从**本机已安装包**
定位资源，仅补缺失文件，不下载、不覆盖现有 TLS 配置：

```bash
sudo /usr/bin/python3 - <<'PY'
from importlib import resources
from pathlib import Path
import subprocess

sources = []
for package, filename in (("certbot_nginx", "options-ssl-nginx.conf"),
                          ("certbot", "ssl-dhparams.pem")):
    root = Path(str(resources.files(package)))
    found = list(root.rglob(filename))
    if len(found) != 1:
        raise SystemExit(f"{package}: 无法唯一定位 {filename}，请核对本机匹配版本的包")
    sources.append((found[0], Path("/etc/letsencrypt") / filename))
subprocess.run(["install", "-d", "-m755", "/etc/letsencrypt"], check=True)
for source, target in sources:
    if not target.exists():
        subprocess.run(["install", "-m644", str(source), str(target)], check=True)
    elif target.stat().st_size == 0:
        raise SystemExit(f"{target} 已存在但为空；请人工核查，不自动覆盖")
PY
```

如果使用其他发行方式，请使用其匹配 Python/包环境定位相同资源；资源不可见时先修复
本机包安装，不要用公网 curl 获取任意版本文件，也不要删除 vhost 的 TLS 指令。
Certbot 官方续期配置说明：
https://eff-certbot.readthedocs.io/en/stable/using.html#modifying-the-renewal-configuration-of-existing-certificates

**不适用的情况：**

- 在 CGNAT 后面（`traceroute` 第二跳是 `10.x`）→ v4 端口映射无效，只能靠 IPv6
- 运营商不给公网 IPv6
- 想同时提供 IPv4 访问 → 做不到，v4 侧无解

---

## Cloudflare 配置

### 1. 托管 NS 并取得 Zone ID

在 Cloudflare 添加域名，把注册商处的 NS 改为**该 zone 控制台分配的那一组**，
等待状态变成 Active。不要照抄其他域名的 NS：

```bash
dig +short NS example.com
```

结果应与控制台一致。在目标域名的**概述（Overview）**页复制 **Zone ID**，
不是 Account ID。程序直接使用 Zone ID，不通过 zone 列表查询来猜测域名归属。

### 2. 创建最小权限 API Token

在个人资料的 **API Tokens → Create Token** 中建立专用 Token：

- 权限只需 **Zone / DNS / Edit**（区域 / DNS / 编辑）。
- Zone Resources 选择 **Include / Specific zone / 你的目标域名**，不要授予所有 zone。
- **不需要 Zone Read**，也不需要账号级权限或 Global API Key。
- DNS Edit 同时覆盖记录查询、创建、更新、删除，供 DDNS 和 DNS-01 共用。

Token 是明文秘密，只显示一次时应妥善保存。安装后保存在 `/etc/v6-ddns/env`
（`root:root 0600`），模板是 `v6ddns/env.example`，**真实凭据不要进 git**。
`V6DDNS_PROVIDER=cloudflare` 只是本分支的配置标识，不是多平台选择开关。

### 3. 记录更新边界

- 新建 AAAA 明确使用 **DNS-only**（`proxied=false`），适合家宽 IPv6 直连。
- 已有 AAAA **仅 PATCH `content`**，不覆盖 `proxied`、TTL、注释等属性。
  已有橙云代理不会自动改成 DNS-only；需要直连时请自己在控制台调整。
- 同名有多个 AAAA 时只同步第一条并发出警告；请人工删除不需要的旧记录，
  否则客户端仍可能轮询到旧地址。脚本不会自动批量删除 AAAA。

### 4. 安装前离线验证

以下命令不需要 root；使用示例凭据，不调用 Cloudflare、certbot 或系统安装：

```bash
bash -n v6-ddns-install.sh
python3 -m unittest discover -s tests -p 'test_install.py' -v
bash ./v6-ddns-install.sh --domain example.com \
  --zone-id 0123456789abcdef0123456789abcdef \
  --token offline-example-token --issue-cert --dry-run
```

测试使用临时路径和 fake commands 检查参数、凭据复用、无副作用计划与证书参数，
并将安装器全部内嵌文件与仓库源码逐字比较。离线通过不能证明真实 Token 权限、
DNS 托管状态、传播速度、CA 签发或公网可达。

---

## 部署后必须手工做的两件事

### 1. 路由器 ACL

脚本管不到路由器。这一步必须自己在管理界面配，而且**配错了很难察觉** ——
最典型的表现是「LAN 内一切正常，出了家门就连不上」。

先确认公网 IPv6 是真的能出网：

```bash
traceroute -4 -n -m 3 1.1.1.1
#   1: 192.168.50.1     ← 你的路由器
#   2: 10.x.x.x        ← 第二跳是私有地址 = CGNAT，v4 端口映射无效
#   2: 公网 IP          ← 第二跳就是公网 = 有公网 v4，端口映射才有用
```

第二跳是 `10.x` 就说明 v4 无解，只能靠 IPv6（这也是本项目的前提）。

**要放行的端口：**

| 端口 | 协议 | 服务 | 必需 |
|---|---|---|---|
| 80 | TCP | nginx（跳 443） | ✅ |
| 443 | TCP | nginx TLS | ✅ |
| 11010 | TCP/UDP | easytier（用 mesh VPN 才需要） | 视情况 |
| 22 | TCP | sshd | 建议**不开** |
| 8317 | TCP | cliproxyapi 管理面板 | 建议**不开** |

**其余一律拒绝。**

#### 爱快的坑：兜底 deny 会误伤出站

爱快 ACL 的「方向」只有**进**和**转发**两个选项。「进」= 进入路由器本身
（比如访问管理页），不是「进入内网设备」—— 你的服务在 `192.168.50.105`
上，是被**转发**过去的，所以规则要选「转发」。

但即使配了「进接口 = WAN1」，兜底 deny 规则**实测仍会影响出站**：
IPv6 出站直接断掉（`ping -6` 100% 丢包、TCP 也全断，不是 ICMP 被过滤），
停用那条 deny 后立刻恢复。

原因是「连接方向匹配」默认关闭 —— 规则不区分「原始方向」（主动发起方）
和「应答方向」（被访问方回应）。**解法是给兜底 deny 打开「连接方向匹配」
并选「原始方向」**：

```
deny 规则（兜底）:
  协议栈        IPv6
  协议          任意
  动作          阻断
  方向          转发
  连接方向匹配   开启          ← 关键
  源方向        原始方向       ← 关键
  进接口        wan1
  出接口        任意
  源/目的地址    - -

allow 规则（白名单）:
  同样的「连接方向匹配=开启 / 原始方向」设置，保持一致
  优先级 0（数字小的先匹配）
  TCP: 80, 443
  UDP: 11010
```

这样：外部扫端口发起的 SYN 属「原始方向」→ 被 deny；本机 `curl -6` 外发
不匹配 → 正常出站。

#### 验证（关键：在 LAN 内测是无效的）

```
① 停用/启用 deny 各测一次出站：
   ping -6 -c3 2400:3200:baba::1
   期望：启用后仍然通。如果不通，说明方向设置还不对。

② 手机关掉 WiFi，用蜂窝网络测端口：
   curl -6 -I http://example.com/         # 期望 301 或 200
   curl -6 -I http://example.com:631/     # 期望不通（CUPS 不该暴露）
```

第②项**必须用蜂窝网络**。在 LAN 内测，流量根本不走 ACL，测什么都是通的。

### 2. 确认公网可达

```bash
# 手机关掉 WiFi，用蜂窝网络
curl -6 -I https://example.com/
```

---

## 工作原理

### 地址是怎么选的

主机在 IPv6 上通常同时持有好几个全球地址：

| 类型 | 标志 | 说明 |
|---|---|---|
| SLAAC EUI-64 | `mngtmpaddr` | 由 MAC 派生，会泄漏 MAC |
| 稳定隐私 | 无 | RFC 7217，内核按 `stable_secret` 生成 |
| 临时地址 | `temporary` | RFC 4941，周期性轮换 |

脚本选**稳定隐私地址**，过滤掉 temporary、deprecated，以及**前缀已不
可路由的地址**。

最后这条是关键。路由器重启换了新前缀后，不会为此发送「撤销 RA」，主机
内核里那个旧地址会继续合法存在 —— 实测 `valid_lft` 约 **70 小时**，而它
早就完全不可路由了。如果只按「新旧」排序（旧的在前面），会一直发布那个
死地址，且因为 state 文件一致而永远不再更新。

判断依据是「地址所在的 /64 是否还在路由器的在链路前缀列表里」：

```bash
ip -6 route show dev enp7s0 proto ra
```

### 两个定时器

| 单元 | 频率 | 作用 | 身份 |
|---|---|---|---|
| `v6-ddns.timer` | 5 分钟 | 选址 → 变了才调 API | root |
| `v6-stale-sweep.timer` | 5 分钟 | 删掉不可路由的旧地址 | root |

清理器让内核不再拿死地址做出站源地址。两个任务相互独立 —— 即使清理器
没跑，DDNS 也不会发布错误地址。

**安全阀**：路由器刚重启、RA 还没到时，在链路前缀列表为空。此时若判定
「所有地址都是死的」正好搞反了，所以脚本在这种情况下什么都不做。

### 证书为什么用 DNS-01

HTTP-01 需要 CA 从公网回连你的 80 端口。实测这里行不通：

- 域名只有 AAAA 记录，LE 的验证只能走 IPv6
- 但 LE 自己的验证节点反复超时（`Timeout during connect`），重试多次均失败
- 同期外部第三方探测是通的，说明路径本身没问题，问题出在 LE 的验证节点

DNS-01 不要求 CA 回连主机：`cloudflare-dns01 auth` 调用 Cloudflare API
创建 `_acme-challenge` TXT，CA 通过 DNS 查询验证，`cleanup` 清理对应验证值。
auth 成功写入后**固定等待 30 秒**再返回，cleanup 不等待；这不是 DNS 传播探测，
不保证所有解析器已可见。申请/续期可能需要更久，不能把 API 写入成功当成各处 DNS
都已可见。目标 zone 的 DNS Edit 同时供创建和清理使用。

### 续期是怎么自动的

`certbot renew` 每次都跑，但只在新证书距过期 ≤30 天时才真正续期。hook
命令存在续期配置里，所以 `certbot.timer`（每天两次）能无人值守完成。

⚠️ **`certonly` 不会自动 reload nginx** —— 续期只更新磁盘上的文件，
nginx 还攥着内存里的旧证书。少了 `renew_hook` 的后果很隐蔽：续期日志
显示成功，`/etc/letsencrypt/live/` 里的证书也确实更新了，但客户端看到的
有效期停在旧日期，直到你手工 restart nginx 才突然生效。

**怎么来的：**

| 签发方式 | renew_hook |
|---|---|
| `--issue-cert`（安装脚本） | 使用独立限域 deploy hook；保留用户自定义 renew_hook |
| 手工 `certbot certonly` | **没有，必须自己补** |

手工签过证书的检查一下：

```bash
grep renew_hook /etc/letsencrypt/renewal/example.com.conf
```

安装器在调用 Certbot **之前**移除旧脚本写入的确切
`renew_hook = systemctl reload nginx` 行，防止重复键导致 lineage 解析失败。
其他自定义 renew_hook 原样保留，不会被替换或删除。

nginx 自动部署脚本位于
`/etc/letsencrypt/renewal-hooks/deploy/v6-ddns-nginx-example.com`，只在 Certbot 的
`RENEWED_LINEAGE` 等于 `/etc/letsencrypt/live/example.com` 时检查并 reload nginx。
重复安装覆盖同一路径，不追加重复 hook。`--issue-cert --no-nginx` 仅移除该脚本及
旧脚本自有的确切 nginx renew_hook，不动用户自定义 hook，也不检查/reload nginx。
手工签发并使用 nginx 时，请单独配置 deploy hook，勿覆盖已有的自定义 renew_hook。

**验证 renew_hook 真的会跑：** `certbot renew --dry-run` **不会**触发它
（dry-run 默认只做验证，不安装证书、不执行续期后的动作）。想确认可以等真实
续期，或者手工执行一次同样的命令看 nginx 是否正常加载：

```bash
sudo nginx -t && sudo systemctl reload nginx && echo "hook 可用"
```

---

## 目录结构

```
/usr/local/bin/v6-ddns              主程序
/usr/local/bin/v6-stale-sweep       旧地址清理
/usr/local/bin/cloudflare-dns01     certbot DNS-01 hook
/usr/local/lib/v6ddns/cloudflare.py Cloudflare API 客户端（仅标准库）
/usr/local/lib/v6ddns/ipv6state.py  地址状态判定
/etc/v6-ddns/env                    凭据，root:root 0600
/var/lib/v6-ddns/address            DDNS 共享状态
/etc/systemd/system/v6-*.{service,timer}
/etc/nginx/conf.d/example.com.conf  80 跳 443
```

凭据放 `/etc` 而不是家目录，是因为 certbot hook 和 `v6-ddns.service` 都以
root 身份运行，读同一个文件，不需要任何身份切换。`0600 root:root` 只有
root 能读，其他用户读不到。

**这个文件里有明文 API Token。** 不要进 git。

---

## 日常运维

```bash
# 看状态
systemctl status v6-ddns v6-stale-sweep
systemctl list-timers 'v6-*'

# 看日志
journalctl -u v6-ddns -f
journalctl -u v6-stale-sweep -f

# 手动触发
systemctl start v6-ddns.service

# 验证续期链路（不消耗配额，不动真实证书）
sudo certbot renew --dry-run

# 证书有效期
sudo certbot certificates
```

### 排查

**域名解析到旧地址**

```bash
# 看公共解析器（注意 TTL 缓存滞后；已有记录保留原 TTL）
dig +short AAAA example.com @223.5.5.5
```

想直查权威，先拿到自己域名的 NS，再将下面示例替换成实际分配的 NS：

```bash
dig +short NS example.com              # 以 Cloudflare 控制台分配结果为准
dig +short AAAA example.com @your-assigned-ns.ns.cloudflare.com
```

Cloudflare 控制台可核对源站记录内容。已有记录若开启代理，公开 DNS 显示的是
Cloudflare 边缘地址，不等于源站 IPv6；这不是 DDNS 更新失败。

**IPv6 出站不通**

这是路由器的问题，不是这套脚本。DDNS 只保证「地址变了 DNS 跟上」，不
保证「地址可用」。在路由器管理页看 WAN → IPv6 的拨号状态。

**日志里的错误码**

| 错误 | 含义 |
|---|---|
| HTTP 401 / 403 或鉴权失败 | 核对 API Token、有效期、目标 zone 范围及 DNS Edit 权限 |
| zone / 记录找不到 | 核对控制台 Zone ID、域名和 host，不要填写 Account ID |
| 多条 AAAA 警告 | 只同步第一条；人工处理其他旧记录 |
| DNS-01 验证失败 | 检查权威 NS、TXT 传播及 hook 日志，不要盲目重复申请 |

---

## 已知的坑

**631 (CUPS) 默认公网可达。** 只要它还在 `[::]:631` 上监听，任何 ACL 引擎
的意外都会让它漏出去。建议：

```bash
sudo cupsctl --listen-ip-address=127.0.0.1
sudo systemctl disable --now cups-browsed
```

主机侧的绑定是内核行为，比依赖路由器实现可靠。

**IPv6 出站突然全断，但 v4 正常。** 先怀疑路由器的兜底 deny ACL（见
[路由器 ACL](#1-路由器-acl)）。特征是：v4 出口地址也变了（说明路由器
整体重拨过），`ping -6` 和 TCP 都断。在路由器管理页把兜底 deny 停用
一下，出站立刻恢复就确认是它。

**外部探测说通了，LE 验证却超时。** 第三方探测节点和 Let's Encrypt 自己的
验证节点走的是不同网络，前者通不代表后者通。遇到这种情况不要反复重试
HTTP-01，直接换 DNS-01。

**8317 开放等于管理面板公网可达。** 如果你有别的服务监听在 `[::]:8317`，
Docker 会绕过 ufw 规则（Docker 的 iptables 链优先级更高）。

**easytier 的 secret 强度。** 用 mesh VPN 的话，`network_secret` 建议改成
随机长串 —— 它就是公网上唯一挡在网网关前面的东西。改完所有 peer 的配置要同步更新。

---

## 关于 `--host` 的选择

默认 `@`（根域）。也可把根域留给其他网站，DDNS 发布到子域：

```bash
--host home      # 记录在 home.example.com，根域留给网站
```

`--host` 控制 AAAA 名称；安装器的 nginx vhost 和 `--issue-cert` 仍面向
`--domain`，不会自动改成子域站点。需要子域 HTTPS 时请另外配置站点和证书域名。

---

## 卸载

```bash
sudo systemctl disable --now v6-ddns.timer v6-stale-sweep.timer
sudo rm -f /etc/systemd/system/v6-ddns.* /etc/systemd/system/v6-stale-sweep.*
sudo rm -rf /usr/local/lib/v6ddns
sudo rm -f /usr/local/bin/v6-ddns /usr/local/bin/v6-stale-sweep /usr/local/bin/cloudflare-dns01
sudo rm -f /etc/letsencrypt/renewal-hooks/deploy/v6-ddns-nginx-example.com
sudo rm -rf /etc/v6-ddns
sudo rm -f /etc/nginx/conf.d/example.com.conf
sudo systemctl daemon-reload
# 别忘了清 certbot 续期配置里的 hook 行，否则续期会失败
sudo certbot delete --cert-name example.com
```
