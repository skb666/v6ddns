# Cloudflare 专用分支实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: 使用 superpowers:subagent-driven-development 执行；按复选框跟踪。

**Goal:** 在 `cloudflare` 分支提供现有 IPv6 DDNS、旧地址清理和证书自动续期的 Cloudflare 版本，`main` 不变。

**Architecture:** 维持 Python 标准库和单文件安装器。用一个 Cloudflare 客户端替代阿里云客户端，由 DDNS 与 certbot hook 共用；安装器内嵌内容与源码逐字一致，不增加服务商抽象。

**Tech Stack:** Python 3 标准库、Bash、systemd、现有 certbot/nginx。

**Spec:** 专用 Git 分支；保留完整功能；`--token` 使用 Cloudflare API Token，新增 `--zone-id`；同步配置、安装器、README 并补离线测试；交付 `cloudflare` 分支，不合并 `main`。

## Global Constraints

- 仅修改 `cloudflare`；`main` 保持 `c60a1c5`。
- 不增加依赖；不添加多平台切换或自动发现 zone。
- 保留 `/etc/v6-ddns/env`、`/var/lib/v6-ddns/address`、现有 systemd 与 IPv6 选址/清理行为。
- Token 只需目标 zone 的 DNS 编辑权限；Zone ID 显式配置为 `V6DDNS_ZONE_ID`。
- 配置和文档默认中文；已有未改动文件不翻译。
- 开发验证使用离线测试和 mocks，不读取或输出真实凭据；真实部署与验收不属于本实现计划的离线验证结论。
- 证书迁移要求 Certbot >= 2.3.0；nginx 模式在写入前验证已有 TLS 配套文件，缺失时提供准备步骤而非自动下载。

## Review Focus

1. 实际 HTTP method 不能被丢弃；已有 AAAA 只 PATCH content，新建明确 DNS-only。
2. API 分页、失败 envelope、非 JSON 和网络错误不能被当成无记录或写入成功。
3. DNS-01 只清理匹配挑战值，缺失 validation 必须拒绝，不能删掉其他 TXT。
4. API 失败或 dry-run 不写地址 state；安装器 dry-run 不修改系统、不输出 Token。
5. 安装器中的程序副本、hook 路径和 README 命令必须与源码一致。

## Task 1：共享客户端与运行脚本（运行实现负责人）

**Files:** 新增 `v6ddns/lib/cloudflare.py`、`v6ddns/bin/cloudflare-dns01`、`tests/test_cloudflare.py`；修改 `v6ddns/bin/v6-ddns`；删除 `v6ddns/lib/alidns.py`、`v6ddns/bin/alidns-dns01`。

**Interfaces:** `cloudflare.ENV_FILE`、`cloudflare.STATE_FILE`、`load_env(path)`、`CloudflareError`；`Client.from_env(path)` 从 `V6DDNS_TOKEN`/`V6DDNS_ZONE_ID` 创建客户端。客户端提供精确名称/类型分页查询、AAAA 创建/更新、TXT 添加与按值删除；具体短方法名由实现者确定。

- [x] 先写标准库 unittest，用 mock urlopen 验证 GET/POST/PATCH/DELETE、Authorization、根域与子域、分页、错误处理；运行得到预期失败并记录原因。
- [x] 最小实现客户端：固定 v4 API；新 AAAA 显式 `proxied=false`；更新只发送 content，保留已有 TTL/proxy/其他元数据；地址不变不调用修改接口；重复 AAAA 保持现有警告而不擅自删记录。
- [x] DDNS 去掉其他平台及 provider 调度，保留配置文件中 `cloudflare` 标识的兼容/校验，缺失 zone/token 明确失败；复用 IPv6 与状态逻辑。
- [x] hook 按实际 `CERTBOT_DOMAIN` 生成 `_acme-challenge` 名并校验在配置域内；允许多个 TXT 挑战共存，清理严格区分大小写并兼容 TXT 外层引号；auth/cleanup 均要求 validation；auth 固定等待 30 秒传播，不增加配置项。
- [x] 用临时目录和 mocks 验证 state 成功才写、dry-run 不写、挑战缺失/域外拒绝；运行 `python3 -m unittest discover -s tests -p 'test_cloudflare.py' -v`。

## Task 2：安装与使用契约（安装文档负责人，与 Task 1 独立写文件）

**Files:** 修改 `v6-ddns-install.sh`、`v6ddns/env.example`、`README.md`、`.gitignore`；新增 `tests/test_install.py`。

**Interfaces:** 安装器增加 `--zone-id ID`；写入 `V6DDNS_PROVIDER=cloudflare`、`V6DDNS_ZONE_ID`、`V6DDNS_DOMAIN`、`V6DDNS_HOST`、`V6DDNS_TOKEN`；安装 `cloudflare.py` 和 `cloudflare-dns01`；证书 hook 改用新路径。

- [x] 先补安装器离线检查，覆盖 dry-run 不写盘/无敏感信息、缺失参数失败、help 与 zone-id；记录预期失败。
- [x] 在任何系统写入前处理 dry-run；不回显 Token。省略参数仅复用相同域名的 Cloudflare 配置，不把旧阿里云凭据当成 Token；配置文件维持 root:root 0600。
- [x] 改 certbot auth/cleanup 路径；已有同名证书用 reconfigure 测试并保存，首次签发显式 cert-name，核验保存配置；`--no-nginx` 不新增 nginx reload；去重必须先于 Certbot 解析，且只移除脚本自有的旧 nginx 命令，不损坏用户 hook；目录 deploy hook 按 lineage 限域。
- [x] 文档说明切换分支、Zone ID/API Token、目标 zone 的 DNS Edit、NS 托管、新记录 DNS-only/已有 proxy 保留、重复 AAAA 警告、证书传播等待与离线验证命令；删除阿里云专属配置。
- [x] 等 Task 1 源码稳定后，逐字同步所有安装器 heredoc 副本；测试提取内嵌文件并与源文件比较，校验 Python/Bash 语法，不运行安装。

## Task 3：协调与验收（父会话负责）

- [x] 基线：工作区干净；`bash -n`、5 个 Python 文件编译和 `git diff --check` 通过；无现成测试套件。
- [x] 创建 `cloudflare` 分支，`main` 未移动。
- [x] 阅读全部变更，核对写入范围与上述约束，完成独立正确性审查；修正后只重跑受影响证据。
- [x] 最终执行 `python3 -m unittest discover -s tests -v`、`bash -n v6-ddns-install.sh`、临时 pycache 下编译全部 Python、`git diff --check`；核对 main 未变且 timer/IPv6/nginx 模板未被意外修改。
- [x] systemd 校验通过；离线测试不承诺真实 API 写权限、证书签发或公网可达性。
- [x] 交付 `cloudflare` 专用分支与验证结果，不合并 `main`。

## 证据预算

- API 与 TXT 安全：Task 1 的离线 HTTP/入口测试；父会话审阅请求载荷和删除条件。
- 安装与副本一致：Task 2 的安全 dry-run 和 heredoc 对比测试；父会话执行完整测试一次。
- main 不变：父会话核对 Git 引用及差异；不重复无关系统验证。
- 限制：mock 不能证明真实 Token 权限、DNS 传播时间、家宽可达性或 CA 实际签发。

## 验收与实施决定

- 离线最终证据：57 项 unittest 通过，Bash/Python 语法、内嵌逐字比较、systemd 校验与 diff 检查通过；Task 1/2 和整分支独立审查的所有发现已关闭。
- 决定：已有同名证书用 Certbot >= 2.3 的 reconfigure 验证后保存，而不强制生产续签；代价是旧版须升级，测试失败时拒绝声称迁移成功。
- 决定：nginx TLS 配套缺失时写入前拒绝并提供本机匹配包资源准备步骤；代价是全新主机需先补文件，不自动联网下载或改变 TLS 模板。
- 限制：DNS-01 auth 成功后固定等待 30 秒，不探测传播完成，不保证所有解析器已可见；真实权限、签发、定时续期与公网可达性需独立验收。
- 功能边界：不自动新增 wildcard DNS 记录。
