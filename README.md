# Nginx VPS 安装器

这是公开仓库 `xik54/nginx-vps-installer` 的内容：一键安装脚本、同步服务和 Ubuntu 集成验证。网站文件与 Nginx 虚拟主机模板放在独立的公开仓库 `xik54/nginx-site-content`。

```text
nginx-vps-installer  ── 初次安装、systemd timer、安全同步脚本
                                 │
                                 ▼
nginx-site-content   ── site/ 或 dist/ 网页文件、可选 nginx/site.conf.template
                                 │
                                 ▼
VPS Nginx            ── 每 5 分钟拉取、nginx -t、成功后重载
```

## 使用方式

仓库建立并推送后，在 Ubuntu 24.04 VPS 上执行（将域名换成自己的）：

```bash
curl -fsSL https://raw.githubusercontent.com/xik54/nginx-vps-installer/main/install.sh \
  | sudo env SITE_DOMAIN=www.example.com bash
```

首次执行会安装 `git`、`nginx` 和 `rsync`，再从两个公开 GitHub 仓库通过 HTTPS 拉取所需文件，无需 Deploy Key、GitHub Token 或第二次运行。

脚本会：

1. 将安装器克隆到 `/opt/nginx-vps-installer`，网站仓库克隆到 `/opt/nginx-site-content`；
2. 创建 Nginx 站点和 `/var/www/github-nginx-site/current`；
3. 立即校验并发布站点；
4. 注册一个每 5 分钟运行的 systemd timer。

网站仓库可放原始静态文件到 `site/`，或放前端构建产物到 `dist/`（例如 Vite 的输出）。若没有 `nginx/site.conf.template`，安装器会为静态站点自动生成基础 Nginx 配置；有模板时则优先使用模板。

若 `/etc/letsencrypt/live/你的域名/` 中已有 Let’s Encrypt 证书，同步脚本会自动监听 `443` 并把 HTTP 重定向至 HTTPS。

之后只需把修改推送到 `main` 分支。下一轮同步会自动拉取、校验并重载 Nginx。

```bash
sudo systemctl start github-nginx-site-sync.service   # 立即同步
sudo systemctl status github-nginx-site-sync.timer
journalctl -u github-nginx-site-sync.service -n 100 --no-pager
```

## HTTPS

本仓库默认仅监听 HTTP `80`，因为域名和证书尚未指定。确认 DNS 已指向 VPS 后，可安装 Certbot 并申请证书。网站应使用 `443`；按你的既有方案，Xray/REALITY 保持在 `8443`，避免端口冲突。

## 安全边界

- `nginx-vps-installer` 与 `nginx-site-content` 都是公开仓库；任何提交内容都可被公众读取与 fork。
- 不得提交密码、API Key、证书私钥、`.env`、用户上传文件或日志。
- 配置未通过 `nginx -t` 时，部署会失败并保留原有的线上 Nginx 配置。
- 安装脚本不会删除其他 Nginx 站点或禁用默认站点。
- GitHub 采用 HTTPS 轮询拉取，无需在 VPS 上保存 GitHub Token 或私钥。

## 本地 Ubuntu 验证

`tests/verify-ubuntu.sh` 会创建本地安装器与网站 bare Git 仓库，调用同一份安装脚本和同步脚本，并用真实的 `nginx -t` 验证首次发布、Git 更新和无效配置回退。它不会读取或使用任何 GitHub 凭据。
