# 下载、安装与权限

## 下载与安装

下载地址：https://github.com/chansigit/remotefinder/releases/latest

需要 macOS 11 或更新版本。选择 `RemoteFinder-版本号-macOS-universal.dmg`；同一个安装包包含 Apple Silicon（M 系列）与 Intel 两种架构，不需要安装 Xcode、Python 或其他运行时。

1. 打开下载的 DMG。
2. 把 `RemoteFinder.app` 拖到旁边的 `Applications`（应用程序）文件夹。
3. 弹出安装磁盘，从「应用程序」打开 RemoteFinder。
4. 按 **⌘K** 新建连接，填写服务器和用户名；端口留空时使用 SSH 配置或默认 22。可保存连接信息，密码不保存。

ZIP 为备用下载：解压后将 `RemoteFinder.app` 移到「应用程序」。不要直接在 ZIP、DMG 或下载预览窗口中运行。没有系统应用目录写入权限时，可放进自己的 `~/Applications` 文件夹。

升级时先退出旧版，再替换应用程序中的 `.app`；连接与收藏保存在用户偏好设置中，不随应用替换而删除。

## 首次打开：无法验证开发者 / Apple 无法检查恶意软件

当前发布包只有本地 ad-hoc 签名，**没有 Developer ID 签名，也没有 Apple 公证**。macOS 可能拦截首次启动。这不是要求你开放磁盘或辅助功能权限。

确认文件来自上面的仓库 Release，且愿意运行这个版本后：

1. 先尝试打开一次 RemoteFinder，关闭拦截提示。
2. 打开 **系统设置 → 隐私与安全性**，在安全性区域找到 RemoteFinder 的拦截记录，点击 **仍要打开（Open Anyway）**。
3. 按系统要求确认或认证，然后打开应用。后续通常可直接启动。

macOS 11–12 对应位置为「系统偏好设置 → 安全性与隐私 → 通用」。如果没有这个按钮，检查是否刚尝试打开过应用；受公司或学校管理的 Mac 可能需要管理员批准。

如果提示「会损坏电脑」、检测到恶意软件，或文件校验不一致，请停止打开并在仓库反馈。提示「已损坏」时先重新下载并校验文件，不要执行网上的全局关闭 Gatekeeper 或 SIP 命令。

Apple 官方说明：https://support.apple.com/102445

## 需要哪些权限

| 情况 | 处理方式 |
| --- | --- |
| 正常浏览 SFTP、下载到缓存、用默认应用打开 | 不需要屏幕录制、辅助功能、自动化或完整磁盘访问权限。 |
| 连接局域网服务器时出现「本地网络」提示 | 确认是自己要连接的服务器后允许；如果之前拒绝，可在「隐私与安全性 → 本地网络」检查对应应用。 |
| 私钥或 SSH 配置依赖「桌面」「文稿」「下载」里的文件，提示无权访问 | 按系统提示仅允许所需目录；也可在「隐私与安全性 → 文件与文件夹」查看已请求的权限。优先把私钥放在自己的 `~/.ssh/`。 |
| 密码、私钥口令、验证码或 Duo 验证提示 | 这是服务器或 SSH 的认证流程，按提示输入；不会保存密码或验证码。 |
| 首次连接出现主机指纹确认 | 先与服务器管理员提供的指纹核对，再确认。已有指纹发生变化时请先联系管理员，不要直接删除校验记录。 |
| 下载后默认应用弹出文件访问提示 | 确认提示中的应用和文件路径，只授权本次所需访问。 |

「文件与文件夹」列表通常只显示曾经请求过相关访问的应用；没有 RemoteFinder 项目不代表安装失败。无需为排错直接开启完整磁盘访问。

Apple 文件权限说明：https://support.apple.com/guide/mac-help/control-access-to-files-and-folders-on-mac-mchld5a35146/mac

Apple 本地网络权限说明：https://support.apple.com/guide/mac-help/mchla4f49138/mac

## SSH 密钥与连接排错

RemoteFinder 使用系统 `/usr/bin/ssh`，沿用 `~/.ssh/config`、密钥和 SSH agent。起始目录可以填 `/data/projects`、`~/projects` 或 `.`（个人目录）。

使用非默认密钥时，在 `~/.ssh/config` 中配置一个 Host 别名，例如：

```sshconfig
Host my-server
    HostName server.example.com
    User alice
    IdentityFile ~/.ssh/id_ed25519
    IdentitiesOnly yes
```

然后在 RemoteFinder 的「服务器」填写 `my-server`；用户名和端口留空以沿用该配置。示例主机、用户名和私钥路径需要换成自己的。

只有当 SSH 明确提示私钥权限过宽（`UNPROTECTED PRIVATE KEY FILE`）时，才针对实际使用的私钥调整权限，例如：

```sh
chmod 700 ~/.ssh
chmod 600 ~/.ssh/id_ed25519
```

上面的私钥名只是示例；不要对整个主目录递归改权限，不要把私钥内容贴到 Issue。

| 提示 | 排查方向 |
| --- | --- |
| `Permission denied (publickey)` | 检查用户、Host 别名、IdentityFile，以及服务器是否已添加对应公钥；这不是 macOS 磁盘权限问题。 |
| `Permission denied`，但已能浏览其他远程目录 | 当前账号没有该服务器目录的读权限；重命名还需要父目录的写权限，请联系目录所有者。 |
| 连接超时 / 连接被拒绝 | 检查主机、SSH 端口、VPN 和服务器状态。无需打开 Mac 的「远程登录」来连接别人的服务器。 |
| 终端可连接，应用失败 | 用系统 `/usr/bin/sftp my-server` 核对是否支持 SFTP；仅支持交互式 SSH shell 的服务器不能用于本应用。检查是否依赖某个终端会话专属的 agent 或环境变量。 |
| 文件已下载但不能打开 | 检查是否安装了对应格式的默认应用。文件保存在 `~/Library/Caches/RemoteFinder/`；本地编辑不会上传。 |

OpenSSH 配置与密钥说明：https://man.openbsd.org/ssh.1

## 可选：核对下载完整性

在 Release 的 Assets 同时下载两个安装包和 `SHA256SUMS.txt`，放在同一个目录，然后运行：

```sh
shasum -a 256 -c SHA256SUMS.txt
```

如果只下载 DMG，可用 `shasum -a 256 RemoteFinder-版本号-macOS-universal.dmg`，将结果与校验文件中对应一行比较。SHA-256 用于检查下载一致性，不能代替 Developer ID 签名或 Apple 公证。

## 已知限制

Universal 包包含两种架构；本次自动测试和运行检查在 Apple Silicon 上完成，尚未在 Intel 真机及所有 macOS 版本逐一验证。

当前支持浏览、本地打开和远程重命名，不支持上传、删除或文件编辑回传。重命名会修改服务器路径。
