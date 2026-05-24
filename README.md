# tizi
vps-tizi

## 总体方案

- 三维矩阵：**客户端类型 × UDP策略 × DNS增强模式**。

- GitHub Private Repo：保存脱敏模板、规则片段、构建脚本
- VPS 本地 secrets：保存真实 Reality 节点参数
- VPS build.sh：合并模板 + secrets + DNS模式 + UDP策略 + 客户端配置
- Nginx：只暴露最终生成的 8 个 mihomo 订阅文件
- Clash Verge / Android：只导入对应远程链接

不要把真实可用配置直接推到 GitHub/Gitee。GitHub 的 private repo 有访问控制，但它仍是第三方平台托管，不等于本地保险箱；公开仓库尤其不适合放密钥，GitHub 也专门提供 secret scanning 来发现泄露的密钥。



## 目录结构

```
./xray-reality
├── common/
│   ├── 01-base.yaml
│   ├── 02-dns-base.yaml
│   ├── 03-proxies.template.yaml
│   └── 04-groups.yaml
├── dns-modes/
│   ├── fake-ip.yaml
│   └── redir-host.yaml
├── rules/
│   ├── 00-local.yaml
│   ├── 10-udp443-block.yaml
│   ├── 10-udp443-allow.yaml
│   ├── 20-reject.yaml
│   ├── 30-proxy-ai.yaml
│   ├── 31-proxy-developer.yaml
│   ├── 32-proxy-google.yaml
│   ├── 33-proxy-social.yaml
│   ├── 34-proxy-microsoft.yaml
│   ├── 40-apple.yaml
│   ├── 50-direct-domestic.yaml
│   └── 90-final.yaml
├── clients/
│   ├── mac.yaml
│   └── android.yaml
├── secrets/
│   └── tmeplate.env.secret
│   └── env.secret（此文件需要根据同目录下的模板创建）
├── build.sh
├── .gitignore
└── README.md
```

- 纳入 Git：

    common/ dns-modes/ rules/ clients/ build.sh .gitignore README.md

- 不纳入 Git：

    secrets/，以及最终生成文件



输出目录

```
├── out
│   ├── mihomo-android-fakeip-allowudp443
│   ├── mihomo-android-fakeip-blockudp443
│   ├── mihomo-android-redirhost-allowudp443
│   ├── mihomo-android-redirhost-blockudp443
│   ├── mihomo-mac-fakeip-allowudp443
│   ├── mihomo-mac-fakeip-blockudp443
│   ├── mihomo-mac-redirhost-allowudp443
│   └── mihomo-mac-redirhost-blockudp443
```







## 脚本

1. 脚本执行权限。
   - `chmod +x ./build.sh`。
   
2. 需要安装两个插件
    1. yq    用来合并、解析、格式化 YAML
    2. envsubst 用来把 `${REALITY_UUID}`、`${REALITY_SERVERNAME}` 这类变量替换成 env.secret 里的真实值
    
    ```bash
    sudo apt update
    sudo apt install -y git wget gettext-base
    
    sudo wget -O /usr/local/bin/yq https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64
    sudo chmod +x /usr/local/bin/yq
    
    yq --version
    envsubst --version
    git --version
    ```
    
    不要用：sudo apt install yq，因为有些系统源里的 `yq` 不是 Mike Farah v4。

















