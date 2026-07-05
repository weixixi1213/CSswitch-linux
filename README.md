# csswitch-linux

在 Linux 上启动 Claude Science，并通过本地 CSSwitch 代理把推理请求转发到 DeepSeek、Qwen/DashScope 或任意 Anthropic 兼容中转站。

这个仓库只包含可开源的启动脚本和代理源码，不包含服务器运行状态、日志、API Key、OAuth Token、Claude Science 数据目录、Bun 缓存或 conda 环境。

## 功能

- 在 `127.0.0.1` 启动本地 CSSwitch 代理。
- 使用独立的沙箱目录，默认位于 `${HOME}/.csswitch-linux`。
- 为沙箱生成本地虚拟 OAuth 状态，不复制、不修改真实 Claude Science 登录凭证。
- 将 Claude Science 的模型请求转发到第三方模型服务。
- 提供启动、停止、状态查看和代理验证脚本。

## 目录结构

```text
.
├── proxy/
│   ├── csswitch_proxy.py      # DeepSeek / Qwen / relay 统一代理
│   ├── dsml_shim.py           # DeepSeek 工具调用兼容 shim
│   └── qwen_proxy.py          # 旧版 Qwen 专用代理
├── scripts/
│   ├── install-linux.sh       # 安装命令链接
│   ├── make-virtual-oauth.py  # 生成沙箱虚拟 OAuth 状态
│   ├── start-linux.sh         # 启动代理与 Claude Science
│   ├── status-linux.sh        # 查看运行状态
│   ├── stop-linux.sh          # 停止服务
│   └── verify-proxy.sh        # 验证代理健康状态
├── requirements.txt
└── LICENSE
```

## 环境要求

- Linux
- `bash`、`curl`、`python3`
- Python 依赖：`cryptography`
- 已安装 `claude-science`，并能在 `PATH` 中找到；或通过 `SCIENCE_BIN=/path/to/claude-science` 指定路径

安装 Python 依赖：

```bash
python3 -m pip install -r requirements.txt
```

安装命令链接：

```bash
sudo scripts/install-linux.sh
```

安装后会得到这些命令：

```bash
csswitch-linux-start
csswitch-linux-fetch-models
csswitch-linux-stop
csswitch-linux-status
csswitch-linux-verify-proxy
```

## 快速开始

DeepSeek：

```bash
csswitch-linux-start --provider deepseek --api-key "$DEEPSEEK_API_KEY"
```

Qwen / DashScope：

```bash
csswitch-linux-start --provider qwen --api-key "$DASHSCOPE_API_KEY"
```

Anthropic 兼容中转站：

```bash
csswitch-linux-fetch-models \
  --provider relay \
  --api-key "$CSSWITCH_RELAY_KEY" \
  --relay-base "$CSSWITCH_RELAY_BASE_URL"
```

```bash
csswitch-linux-start \
  --provider relay \
  --api-key "$CSSWITCH_RELAY_KEY" \
  --relay-base "$CSSWITCH_RELAY_BASE_URL" \
  --relay-model "claude-sonnet-5"
```

涓嶄紶 `--relay-model` 鏃讹紝鍚姩鑴氭湰浼氬厛鑷姩鎷?relay 鐨?`/v1/models`锛岄粯璁ら€夌涓€涓繑鍥炴ā鍨嬩綔涓哄浐瀹氭ā鍨嬨€?

查看状态：

```bash
csswitch-linux-status
```

停止：

```bash
csswitch-linux-stop
```

## 常用参数

- `--provider deepseek|qwen|relay`：选择上游服务。
- `--api-key <key>`：上游 API Key 或中转站 Token。
- `--relay-base <url>`：relay 模式的 Anthropic 兼容接口地址。
- `--relay-model <model>`：relay 模式下固定映射到某个模型，可选。
- `--proxy-port <port>`：本地代理端口，默认 `18991`。
- `--science-port <port>`：Claude Science Web 端口，默认 `8000`。
- `--sandbox-port <port>`：沙箱服务端口，默认 `8001`。
- `--state-root <dir>`：运行状态目录，默认 `${HOME}/.csswitch-linux`。
- `--email <email>`：虚拟本地账号邮箱，默认 `virtual@localhost.invalid`。

也可以使用环境变量：

- `DEEPSEEK_API_KEY`
- `DASHSCOPE_API_KEY`
- `CSSWITCH_RELAY_KEY`
- `CSSWITCH_RELAY_BASE_URL`
- `CSSWITCH_RELAY_MODEL`
- `SCIENCE_BIN`
- `PYTHON_BIN`
- `STATE_ROOT`

## 运行目录

默认运行目录是：

```text
${HOME}/.csswitch-linux
```

其中会生成：

- `run/`：pid、代理 path secret 等运行时文件。
- `logs/`：代理和 Claude Science 启动日志。
- `home/`：隔离的 Claude Science 沙箱 home。

这些文件都属于本机运行状态，不应该提交到 GitHub。

## 安全边界

- 不读取、不复制、不修改真实 `~/.claude-science` 登录数据。
- 沙箱使用独立目录，默认写入 `${HOME}/.csswitch-linux/home/.claude-science`。
- 代理会剥离 Claude Science 请求里的入站 `Authorization` 和 `x-api-key`，不会把本地 OAuth Bearer 原样转发给第三方。
- 上游 API Key 通过命令参数或环境变量传入，只在代理进程内使用。
- 本地代理默认只监听回环地址，并用 path secret 保护推理接口。

## 故障排查

查看运行状态：

```bash
csswitch-linux-status
```

验证代理：

```bash
csswitch-linux-verify-proxy
```

查看日志：

```bash
ls -lah "${HOME}/.csswitch-linux/logs"
```

如果 `claude-science` 不在 `PATH` 中，可以显式指定：

```bash
SCIENCE_BIN=/path/to/claude-science csswitch-linux-start --provider deepseek --api-key "$DEEPSEEK_API_KEY"
```

如果系统里有多个 Python，可以指定：

```bash
PYTHON_BIN=/path/to/python3 csswitch-linux-start --provider qwen --api-key "$DASHSCOPE_API_KEY"
```

## 开源说明


## 许可证

MIT
