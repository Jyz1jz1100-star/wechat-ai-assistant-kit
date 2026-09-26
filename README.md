# 微信 AI 助手（可自配版）

在手机微信里跟自己的 AI 助手单聊。走**腾讯官方开源的微信通道插件 + OpenClaw**，
出站长轮询，所以**不需要公网服务器、不需要域名、不需要备案、不需要内网穿透**。

它跑在你自己的电脑上。**电脑关机或休眠时它不回应** —— 这是这套方案的固有代价。

> 先读 `docs/ROUTE.md`：为什么公众号、微信客服、PC hook 那些路走不通，
> 以及这条路的真实风险。别跳过风险那一节。

---

## 你需要准备什么

| 东西 | 说明 |
|---|---|
| 一台常开的电脑 | Windows / macOS / Linux 都行 |
| Node.js **≥ 22.13** | <https://nodejs.org> 装 LTS 即可 |
| 一个模型的 **OpenAI 兼容端点 + key** | DeepSeek、OpenRouter、DashScope、Kimi、智谱、自建网关都算 |
| 一个微信号 | 扫码授权的会是**一个独立 Bot 账号**，不接管你的微信号 |

## 三步装好

```bash
git clone <这个仓库>
cd <仓库目录>
```

**1. 填 provider** —— 编辑 `config/openclaw.patch.json`，把三处换成你自己的：

```jsonc
"models": { "providers": {
  "myprovider": {                       // ① 随便起名，下面 primary 要跟着改
    "baseUrl": "https://api.deepseek.com/v1",   // ② 你的端点
    "apiKey": "${ASSISTANT_API_KEY}",   // ③ 保持这样，别把 key 写进来
    "api": "openai-completions",
    "models": [ { "id": "deepseek-v4.1-flash", "name": "显示名" } ]   // ④ 上游模型全名
  }
}},
"agents": { "defaults": { "model": { "primary": "myprovider/deepseek-v4.1-flash" } } }
```

`primary` 的格式是 `provider名/模型id`。`workspace` 路径**不用填** ——
`apply-config.mjs` 会按仓库所在位置自动写进去。

**2. 装 + 配**（Windows）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\install.ps1
```

macOS / Linux：照着 `scripts/install.ps1` 里的五条命令逐条跑同样的
（`npm install -g openclaw` → `openclaw plugins install "@tencent-weixin/openclaw-weixin"`
→ `openclaw config set plugins.entries.openclaw-weixin.enabled true`
→ `node scripts/apply-config.mjs` → `openclaw config validate`）。

**3. 录密钥 + 扫码**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\set-key.ps1
openclaw channels login --channel openclaw-weixin   # 出二维码，手机微信扫码
openclaw gateway install                            # 装成常驻服务
```

⚠️ **一定要 `gateway install`**，不能只 `restart`。实测：对从未安装过的服务
`restart` 是空转且不报错，你会得到"配置全对、扫码成功、但助手不回话"。

想双击启动的话跑一次 `scripts\build-exe.ps1`，桌面会生成一个启动器
（只有 4KB，不含逻辑，只是打开 `scripts\quickstart.ps1`）。

## 日常

手机微信直接发消息。等几秒正常，期间会显示"正在输入"。

坏了先跑体检，它逐项告诉你哪里不对、只给第一条修法：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\doctor.ps1
```

| 现象 | 原因 | 做什么 |
|---|---|---|
| 完全没反应 | 电脑睡了 / 网关停了 | `openclaw gateway restart`，再跑 doctor |
| doctor 说 网关在运行 FAIL | 服务没装 | `openclaw gateway install` |
| doctor 说 微信通道已连 FAIL 且提到 config-only | **不是**没扫码，是网关不可达 | 先修网关那一项 |
| doctor 说 模型密钥 FAIL | key 无效或没额度 | 去服务商后台确认，再跑 `set-key.ps1` |
| 突然 1 小时都不回 | 被微信侧限流（协议里的 `-14`） | 等一小时，**别连续重试发消息** |
| 回答里中文变问号 | 有脚本用 shell 拼 JSON | 是 bug，见 `docs/NOTES.md` |

## 改性格、加资料

都在 `workspace/` 下，改完下一轮对话生效，不用重启：

| 文件 | 管什么 |
|---|---|
| `IDENTITY.md` | 名字 |
| `SOUL.md` | 怎么说话 |
| `USER.md` | 你是谁、你的偏好 |
| `AGENTS.md` | 工作约定与边界 |
| `knowledge/` | 你的资料（`.md`/`.txt`，PDF 建议先转文本） |

助手用 grep + 读文件在 `knowledge/` 里检索，**没有向量库**。几百份文件内这样够用；
什么时候该升级成真正的检索，见 `docs/NOTES.md`。

**不要**把不愿让服务商看到的内容放进 `knowledge/` 或发给它。

## 跑测试

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\test.ps1
```

覆盖配置合并、体检判定、编码守卫。逻辑都在可测的位置，不需要真装 OpenClaw 也能跑。

## 许可与免责声明

MIT。微信通道插件是腾讯的开源项目，本协议接入没有公开契约，
存在账号被限制的**真实风险**。作者不对账号状态、消息丢失、模型回答质量负责。
纯个人自用；一旦拿去对外提供服务，可能触发生成式 AI 相关的备案与内容标识义务。
