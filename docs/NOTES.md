# 工程笔记：Windows/PowerShell 的真实陷阱

这一页全是踩出来的。换机器、改脚本前先扫一遍，能省掉几小时的诡异现象。

## 1. `.ps1` 必须存成 UTF-8 **with BOM**

PowerShell 5.1 读**没有 BOM** 的 `.ps1` 时按系统 ANSI 代码页（简体中文即 GBK）解码。
后果不是乱码报错，而是**中文注释的字节序列会吞掉紧随其后的那一行代码**：

```powershell
# 这是一句中文注释
$global:Counter = @{ Passed = 0 }   # ← 这行可能整条消失，且不报语法错误
```

现场表现是"函数定义了但调用说不存在"、变量莫名其妙是 null。
本仓库用 `tests/test-encoding.ps1` 逐文件守住 BOM，任何编辑器重存导致丢 BOM 都会被抓。

反过来：**`.env` 必须无 BOM** —— BOM 会把第一行的键名变成 `<BOM>KEY`，读不到。

## 2. 中文经 shell 传 HTTP 会碎

Git Bash + curl 的命令行参数会被按 GBK 处理，UTF-8 中文进 body 就变成 `??`。
服务端拿到的就是碎字（模型会反问"你的问题是不是乱码了"）。

对策：所有 HTTP 请求走 PowerShell / Node 并**显式** `encode('utf-8')`，
**绝不用 shell 拼 JSON**。控制台还要设
`[Console]::OutputEncoding = [System.Text.Encoding]::UTF8`，否则中文输出是乱码。

## 3. `& $exe` 在命令不存在时是**抛异常**，不是返回非零码

于是"没装"会被误报成"版本过低"（因为版本字符串是空的），把人往错方向引很久。
`Invoke-External` 先用 `Get-Command` 探一次，并在结果里带 `Missing` 标记。

## 4. `$ErrorActionPreference = 'Stop'` 会被原生命令的 stderr 咬到

命令行工具把**正常告警**写到 stderr 是很普遍的。开了 Stop，这些告警会变成终止错误，
脚本在只读步骤上直接崩。所以 `install.ps1` / `doctor.ps1` 用 `Continue`
+ 显式检查 `$LASTEXITCODE`。

## 5. `Read-Host -AsSecureString` 在 stdin 被重定向时**永久卡住**

它不会返回空值，而是继续等控制台输入。用 `< /dev/null` 做自动化验证时表现为整个脚本挂死，
日志停在提示行之后。对策：先判 `[Console]::IsInputRedirected`，非交互就明确报错退出。

## 6. PowerShell 5.1 没有这些 7.x 语法

`Join-String`、`??`、三元 `? :`、`ForEach-Object -Parallel` 都会当场报错。
写脚本只用 5.1 兼容语法。

## 7. 函数参数不要命名为 `Args`

`$Args` 是 PowerShell 的自动变量。把参数命名成 `Args` 会让注入的假函数
**永远收不到参数**，测试静默失效。本仓库统一用 `-CmdArgs`。

## 8. 参数声明 `[hashtable]` 会挡掉 `[ordered]@{}`

`[ordered]@{}` 实际类型是 `OrderedDictionary`。声明成 `[hashtable]` 会在参数绑定阶段
直接报错。接收检查表的地方用 `[System.Collections.IDictionary]`。

## 9. 幂等判据必须是**语义**比较

配置合并若用"文本变没变"判幂等，会因为磁盘文件的缩进、键序、尾随换行跟我们生成的
不一致而**每次都误判有改动** —— 于是每次重跑都白刷备份、触碰用户文件时间戳。
`config-merge.mjs` 排序键后再序列化来比较，`tests/config-merge.test.mjs` 有专门回归用例。

## 10. 别并发跑 npm 安装

npm 全局装一个大型 CLI 时会先删旧再写新。期间再开一个安装/重装进程，会把内容哈希
命名的 bundle chunk 撕开，事后报 `Cannot find module 'xxxx-<hash>.mjs'`。
这种坏状态**看起来像装成功了但一跑就崩**。串行，一次装完再动。

## 11. `openclaw gateway restart` 对从未安装的服务是空转且不报错

这是最容易让人以为"我配错了"的一个坑。必须 `openclaw gateway install` 才会真正建常驻服务。
`quickstart.ps1` 已经改成先探测、没装就装。

## 12. 通道状态探测在网关不可达时只会念配置文件

`channels status --probe` 拿不到网关连接时会输出 `showing config-only status`，
那一行**永远不会**出现 `running` / `connected`。把它解释成"你没扫码"是错误诊断
（真人案例：已经扫过码的人被反复要求重扫）。`Check-ChannelConnected` 现在识别
config-only 并把修法指向网关，同时把"凭据在不在盘上""网关在不在跑""通道连没连"
拆成三项分别报告。

## 检索什么时候该升级

`knowledge/` 用 grep + 读文件，不建索引。判据写死，避免凭感觉重构：

> 当用户明确问某份资料里的内容，而 grep + 定向 read **连续 3 次**未命中时，才引入
> embedding 检索。届时换的是检索实现，`AGENTS.md` 的检索约定接口不变。

几百份文件以内，向量层带来的维护成本（索引、重建、陈旧检测）明显高于收益。

## 延迟长尾是常态，不是异常

推理型模型的响应里 `reasoning_tokens` 常常占大头，端到端延迟中位几秒、长尾能到十几秒。
所以**不要**为"5 秒内同步返回"做设计。这条通道本来就是异步的，慢不是错误。
若要压延迟，先确认端点支持不支持把推理档位调低。
