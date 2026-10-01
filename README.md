# v6-ddns — 家宽 IPv6 动态域名 + 自动续期证书

给「路由器后面、家宽 IPv6 直连」的场景做的**一条龙部署**。不需要公网 IPv4。

解决的问题：家宽的 IPv6 前缀会变（电信重拨、路由器重启都会换），静态
DNS 记录迟早指向一个你不拥有的地址，公网就再也连不上了。这套东西负责
「盯着地址 → 变了就更新 AAAA → 证书自动续期」。

---

## 快速开始

```bash
sudo apt install -y certbot python3-certbot-nginx     # 首次需要
sudo ./v6-ddns-install.sh \
    --domain example.com \
    --token 'AKID,AKSECRET' \
    --issue-cert
```

`--token` 是阿里云 AccessKeyId,AccessKeySecret。已有 `/etc/v6-ddns/env`
时可以省略，会沿用。

部署完成后还剩两步必须手工做，见 [部署后](#部署后必须手工做的两件事)。

### 全部参数

| 参数 | 说明 |
|---|---|
| `--domain NAME` | 域名，**必填** |
| `--token AK,SK` | 阿里云凭据。省略则沿用已有 `/etc/v6-ddns/env` |
| `--host LABEL` | 记录标签，默认 `@`（根域）。`home` → `home.example.com` |
| `--issue-cert` | 部署后立即申请证书 |
| `--no-nginx` | 跳过 nginx vhost |
| `--dry-run` | 只打印不执行 |

---

## 前置条件

**必须满足：**

1. 运营商给了**公网 IPv6**，且路由器把前缀委派给了内网
2. 路由器 IPv6 出站正常（`ping -6 2400:3200:baba::1` 通）
3. 域名 NS 指向阿里云 DNS（见 [阿里云配置](#阿里云配置)）
4. 阿里云 RAM 用户已建好并授权（见 [阿里云配置](#阿里云配置)）

**主机依赖：**

```bash
sudo apt install -y certbot python3-certbot-nginx iproute2 python3
```

**不适用的情况：**

- 在 CGNAT 后面（`traceroute` 第二跳是 `10.x`）→ v4 端口映射无效，只能靠 IPv6
- 运营商不给公网 IPv6
- 想同时提供 IPv4 访问 → 做不到，v4 侧无解

---

## 阿里云配置

两件事：确认域名托管在阿里云，建一个只有 DNS 权限的 RAM 用户。

### 1. 确认 NS 已指向阿里云

```bash
dig +short NS example.com
```

期望看到 `ns1.alibabadns.com.` / `ns2.alibabadns.com.`。

⚠️ 老教程里写的 `ns*.dns.companion.com` **已经失效** —— 那个域名过期被
停放商接管了，别照抄。

权威 NS 是 `ns1/ns2.alibabadns.com`。反过来在阿里云控制台确认：
**DNS → 域名解析 → 域名列表**，域名在列表里就是已托管。

### 2. 建 RAM 用户

**不要用主账号的 AccessKey。** 建一个专用 RAM 用户，只给 DNS 权限。

1. 打开 https://ram.console.aliyun.com/ ，用**主账号**登录
2. 左侧导航 **身份 → 用户** → **创建用户**
3. **登录名称** 填 `v6-ddns`（字母/数字/点/横线/下划线，≤64 字符）
4. **访问方式** 只勾 **Permanent AccessKey**
   - **不要勾 Console Access** —— 脚本不需要登录控制台，少一个攻击面
5. 勾上「我确认必须创建 AccessKey」的复选框，否则按钮点不动
6. 确定 → **`AccessKeySecret` 只显示这一次**，页面关掉就再也看不到

### 3. 建自定义权限策略

左侧 **权限 → 权限策略 → 创建权限策略** → 选「脚本编辑」→ 粘贴：

```json
{
  "Version": "1",
  "Statement": [{
    "Effect": "Allow",
    "Action": [
      "alidns:DescribeSubDomainRecords",
      "alidns:AddDomainRecord",
      "alidns:UpdateDomainRecord",
      "alidns:DeleteDomainRecord"
    ],
    "Resource": "*"
  }]
}
```

策略名填 `v6ddns-minimal`。

`Resource` 只能写 `*`：Alidns 这几个接口不支持资源级授权，这是产品限制。

> 不想建自定义策略的话，系统策略 `AliyunDNSFullAccess` 也能跑通，但它是
> DNS 全量管理权（能删光所有记录、改 NS）。一个无人值守跑在别人机器上的
> 凭据，建议最小权限。
> 菜单找不到就直接用控制台顶部搜索框搜「自定义权限策略」。

### 4. 授权给用户

**身份 → 用户** → 点进 `v6-ddns` → **权限管理**（或 Actions 列的「附加策略」）
→ 资源范围选**账号级** → 权限策略类型选**自定义策略** → 搜 `v6ddns-minimal`
→ 勾选 → 确认。

**立即生效**，不用重新登录、不用等。

### 5. 四个 Action 的用途

| Action | 什么时候用 | 缺了会怎样 |
|---|---|---|
| `DescribeSubDomainRecords` | 每次运行，查询现有记录 | 必装，否则什么都做不了 |
| `AddDomainRecord` | 首次部署、`--host` 换记录名 | 必装 |
| `UpdateDomainRecord` | 地址变化时更新 | 必装 |
| `DeleteDomainRecord` | 每次 certbot 续期后删 TXT | 缺失则 `_acme-challenge` 下每次续期都留一条垃圾 TXT |

前三个装完就能跑；第四个可以后补，但补之前每次续期都会堆积 TXT 记录。

### 6. 填入安装脚本

```bash
sudo ./v6-ddns-install.sh \
    --domain example.com \
    --token '你的AccessKeyId,你的AccessKeySecret' \
    --issue-cert
```

凭据落在 `/etc/v6-ddns/env`（`root:root 0600`）。**这个文件里有明文
AccessKey，不要进 git。**

安装脚本调用阿里云 API 用的签名是 AliRPC HMAC-SHA1，双层编码（`:` → `%3A`
→ `%253A`）—— 这部分在 `lib/alidns.py` 里，别自己改。

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

DNS-01 完全不碰入站端口，CA 只跟阿里云 API 对话，所以稳定。

**前提：RAM 用户要有 `alidns:DeleteDomainRecord`**，否则每次续期会在
`_acme-challenge` 留下垃圾 TXT 记录。

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
| `--issue-cert`（安装脚本） | 自动加，无需手工处理 |
| 手工 `certbot certonly` | **没有，必须自己补** |

手工签过证书的检查一下：

```bash
grep renew_hook /etc/letsencrypt/renewal/example.com.conf
```

没有输出就补上：

```bash
echo 'renew_hook = systemctl reload nginx' | sudo tee -a /etc/letsencrypt/renewal/example.com.conf
```

**验证 renew_hook 真的会跑：** `certbot renew --dry-run` **不会**触发它
（dry-run 只做验证，不安装证书、不执行续期后的动作）。想确认只能等真实
续期，或者手工执行一次同样的命令看 nginx 是否正常加载：

```bash
sudo nginx -t && sudo systemctl reload nginx && echo "hook 可用"
```

---

## 目录结构

```
/usr/local/bin/v6-ddns              主程序
/usr/local/bin/v6-stale-sweep       旧地址清理
/usr/local/bin/alidns-dns01         certbot hook
/usr/local/lib/v6ddns/alidns.py     阿里云 API 客户端（HMAC-SHA1 签名）
/usr/local/lib/v6ddns/ipv6state.py  地址状态判定
/etc/v6-ddns/env                    凭据，root:root 0600
/etc/systemd/system/v6-*.{service,timer}
/etc/nginx/conf.d/example.com.conf  80 跳 443
```

凭据放 `/etc` 而不是家目录，是因为 certbot hook 和 `v6-ddns.service` 都以
root 身份运行，读同一个文件，不需要任何身份切换。`0600 root:root` 只有
root 能读，其他用户读不到。

**这个文件里有明文 AccessKey。** 不要进 git。

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
# 看公共解析器（注意 TTL 缓存滞后，TTL 600 时最多滞后 10 分钟）
dig +short AAAA example.com @223.5.5.5
# 直接问阿里云 API，绕过所有缓存，最可靠
python3 -c "import sys; sys.path.insert(0,'/usr/local/lib/v6ddns'); import alidns; \
  print(alidns.Client.from_env('/etc/v6-ddns/env').records('@.example.com','AAAA'))"
```

想直查权威，先拿到自己域名的 NS：

```bash
dig +short NS example.com              # 例：ns1.alibabadns.com.
dig +short AAAA example.com @ns1.alibabadns.com
```

⚠️ 阿里云权威 NS 目前只有 IPv4 记录（`140.205.103.192` 等），所以 v6 出站
不通时照样能查。但老教程里写的 `ns*.dns.companion.com` **已经失效** ——
那个域名过期被停放商接管了，别照抄。

排查「域名解析到旧地址」时，注意公共解析器有 TTL 缓存。要立刻看到真值，
用阿里云 API 那条，别用 `dig`。

**IPv6 出站不通**

这是路由器的问题，不是这套脚本。DDNS 只保证「地址变了 DNS 跟上」，不
保证「地址可用」。在路由器管理页看 WAN → IPv6 的拨号状态。

**日志里的错误码**

| 错误 | 含义 |
|---|---|
| `Specified signature is not matched` | 代码 bug，不是凭据问题 |
| `DomainRecordDuplicate` | 更新成了与现状相同的值，代码已规避 |
| `Forbidden.RAM` | RAM 用户缺对应 Action |
| `MissingDomainName` / `MissingRR` | 请求参数缺失 |

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

**阿里云报 `SignatureDoesNotMatch`。** 如果你改过 `lib/alidns.py`，注意
AliRPC 签名是**双层编码**：每个 key/value 先单独编码，拼好的串再整体编码
一次，所以时间戳会显示成 `%253A`（`:` → `%3A` → `%253A`），而且待签字符串
前面还有 `GET&%2F&` 前缀。别凭记忆简化。

---

## 关于 `--host` 的选择

默认 `@`（根域），但**根域有个限制**：

阿里云的 `UpdateDomainRecord` 对根域记录（`RR=@`）有个坑 —— 更新成与现状
**相同的值**会报 `DomainRecordDuplicate`。代码已通过「与 DNS 实际值比对」
规避，所以根域是可以用的。

如果想更省心，用子域：

```bash
--host home      # 记录在 home.example.com，根域留给网站
```

子域不受那个限制影响。

---

## 卸载

```bash
sudo systemctl disable --now v6-ddns.timer v6-stale-sweep.timer
sudo rm -f /etc/systemd/system/v6-ddns.* /etc/systemd/system/v6-stale-sweep.*
sudo rm -rf /usr/local/lib/v6ddns
sudo rm -f /usr/local/bin/v6-ddns /usr/local/bin/v6-stale-sweep /usr/local/bin/alidns-dns01
sudo rm -rf /etc/v6-ddns
sudo rm -f /etc/nginx/conf.d/example.com.conf
sudo systemctl daemon-reload
# 别忘了清 certbot 续期配置里的 hook 行，否则续期会失败
sudo certbot delete --cert-name example.com
```
