# 源码构建

要求：macOS 13 或更新版本，Xcode Command Line Tools，Swift 5.9 或更新版本。

```sh
xcode-select --install
# 下载源码后，在项目根目录运行
./build.sh
open .build.noindex/PromptShelf-Open.app
```

构建只使用系统框架，不需要 npm、云数据库、账号服务或下载第三方运行时。默认构建当前电脑的架构，可指定 `ARCH=arm64` 或 `ARCH=x86_64`。发行包的实测平台在发行记录中标明。

运行本地回归检查（使用临时目录和独立偏好、剪贴板）：

```sh
scripts/verify.sh
```

运行真实模型与完整任务验证（需要本机 Ollama 和已经下载的模型）：

```sh
PROMPTSHELF_OPEN_DATA_DIR="$PWD/.verification/manual-model" \
PROMPTSHELF_OPEN_TEST_MODEL="你的本机模型名称" \
.build.noindex/PromptShelf-Open.app/Contents/MacOS/PromptShelf-Open --workflow-check
```

以上真实检查会连接 `127.0.0.1:11434`，分别验证 Ollama 和 OpenAI 兼容接口，然后处理生成的虚构会议文件、依次执行三个步骤，并检查失败、取消、记录恢复和退出保存。没有模型变量时仅做本地逻辑检查；不会把模拟结果当成模型实测。

Keychain 回归检查使用随机命名的隔离服务，正常检查后删除该测试密钥；不访问用户原有密钥。无图形登录会话的 CI 可以设置 `PROMPTSHELF_OPEN_SKIP_KEYCHAIN_TEST=1` 跳过此项；CI 不承担桌面输入或真实模型验收。

制作 ZIP 和 DMG：

```sh
scripts/package.sh
```

输出位于 `dist/`，同时生成 SHA-256 校验文件。当前构建采用本机临时签名；没有 Apple Developer ID 签名和公证，不应将其描述为已公证安装包。
