# GitHub 下载加速与回退策略

## 设计目标

GitHub 加速服务会因地区、网络和运营状态而变化，安装脚本不应假定某个固定服务始终可用。本项目使用多来源回退，并始终保留官方 GitHub 直连作为最后选择。

## URL 模板

镜像条目统一使用 `{url}` 占位符，脚本会将其替换为完整的原始 GitHub HTTPS URL：

```text
https://gh-proxy.com/{url}
```

例如原始地址为：

```text
https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-arm64-v1.19.12.gz
```

生成的加速地址为：

```text
https://gh-proxy.com/https://github.com/MetaCubeX/mihomo/releases/download/v1.19.12/mihomo-linux-arm64-v1.19.12.gz
```

当前内置文件加速节点（按优先级）：

1. `https://gh-proxy.com/{url}`
2. `https://ghproxy.net/{url}`
3. `https://ghproxy.homeboyc.cn/{url}`
4. `https://github.akams.cn/{url}`
5. `https://ghp.ci/{url}`
6. `https://github.moeyy.xyz/{url}`
7. `http://toolwa.com/github/{url}`
8. 官方 GitHub 直连（自动追加）

这种方式避免了旧版“去掉协议后直接拼接”的歧义，也便于兼容不同加速服务的规则。

## 自定义镜像

可用环境变量覆盖内置镜像，条目以逗号分隔：

```bash
GITHUB_MIRRORS='https://proxy-a.example/{url},https://proxy-b.example/{url}' \
  bash quick_install.sh
```

不论是否自定义，官方 GitHub 地址都会自动追加为最后的回退来源。

## 下载校验

下载结果会先保存到临时文件，只有通过以下检查才会移动到最终路径：

- 最小文件大小；
- 拒绝 HTML/XML 错误页；
- `.gz`、`.tgz`、`.zip` 压缩包完整性检查；
- 远程 shell 脚本必须包含 shebang。

## 排查命令

在运行完整下载前，可打印各镜像最终生成的地址：

```bash
./test_github_mirrors.sh --print-urls
```

也可以执行完整镜像测试（会下载测试文件）：

```bash
./test_github_mirrors.sh
```
