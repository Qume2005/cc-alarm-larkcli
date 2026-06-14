---
name: cc-alarm-larkcli
version: 1.0.0
description: "用 lark-cli 给你发飞书消息：任务完成、需要确认、长任务进度、出错告警。当 agent 跑完任务、卡在决策、跑训练/编译等长任务要周期 ping、或任务失败时调用 notify.sh 推一条飞书通知。轻量、非致命、节流友好。现已为插件，含自动 hook 在 Stop/SubagentStop/Notification 事件自动推送。"
metadata:
  requires:
    bins: ["lark-cli"]
  cliHelp: "lark-cli im +messages-send --help"
---

# cc-alarm-larkcli (v1)

给 Claude Code 子 agent 用的飞书通知小工具。一个脚本 `notify.sh`，四种消息类型，覆盖「需要你介入 / 任务完成汇报 / 长任务进度 / 任务失败」。通知是锦上添花，不是关键路径——发送失败绝不阻塞主任务。

## 何时用（四种场景，直接复制即可）

收件人**默认发给你自己**——只要 `lark-cli auth login` 过，不用配置就能用（见末尾「前置条件」+ README）。脚本路径恒可解析——技能会被软链到 `~/.claude/skills/cc-alarm-larkcli`，所以一律用绝对路径 `~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh`。

### 1. 需要你确认 / 决策（ask）

agent 卡在分支选择、合并确认、二选一时，ping 一下等回复。

```bash
bash ~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh ask "需要你确认：是否合并到 main？当前 12 个测试全过"
```

### 2. 任务完成（done）

agent 跑完整个任务，发一条收尾汇报。

```bash
bash ~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh done "认证模块重构完成，12 个测试全过"
```

### 3. 长任务进度（progress）

深度学习训练、大型编译、长跑 job 期间周期性 ping。**默认 5 分钟节流**——连续发会被吞掉（exit 0，stderr 提示），紧迫时加 `--force` 突破。

```bash
# 周期 ping，默认 5 分钟一次
bash ~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh progress "epoch 7/20, loss=0.23"

# 紧迫场景，强制立即发（突破节流）
bash ~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh progress "epoch 7/20 loss 异常飙升" --force
```

### 4. 任务失败（error）

任务挂了，把失败点 push 出来。

```bash
bash ~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh error "编译失败，见 build.log:42"
```

## 自动 Hook 通知（插件内置）

本技能现在是一个 **`@skills-dir` 插件**（`.claude-plugin/plugin.json` + 软链 `~/.claude/skills/cc-alarm-larkcli`），Claude Code 启动时自动发现加载，**零安装、无需 marketplace**。插件带 3 个自动 hook：在生命周期事件触发时**直接调用 `notify.sh` 发飞书**，不依赖模型记得用 skill——agent 一停下或等你输入，就自动推送。

| Hook 事件 | 触发时机 | → notify.sh type | 正文来源 |
|---|---|---|---|
| `Notification` | agent 等你授权 / 空闲 | `ask` 🙋 | hook stdin 的 message |
| `Stop` | 主 agent 每轮结束 | `done` ✅ | 读本轮 transcript 最后 assistant 文本（截 200 字）；读不到则回退 "主 agent 一轮结束" |
| `SubagentStop` | 子 agent 完成 | `done` ✅ | 读 transcript 最后 assistant 文本；读不到则回退 "子 agent 完成" |

**节流（脚本内，防刷屏）**：`done` 默认 120s、`ask` 默认 60s；在 `~/.config/cc-alarm-larkcli/config.sh` 用 `HOOK_THROTTLE_DONE` / `HOOK_THROTTLE_ASK`（秒数）覆盖。`progress` 仍用 `THROTTLE_SECONDS`（手动场景）。

**发送失败非致命**：hook 永远 `exit 0`、绝不阻塞 agent。lark-cli 没配好（`exit 2`）或网络抖动也只是静默不发，主任务照跑。

**激活**：装好后需 **重启 Claude Code 或执行 `/reload-plugins`**，hook 才会被注册生效。第一次安装或改了 `hooks/hooks.json` 后必须做这一步，否则自动推送不工作。

**手动调用仍可用**：上面四个场景的 `bash ~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh ask/done/progress/error "..."` 依然有效，适合 ad-hoc 自定义推送（如长任务中途主动 ping `progress`、或想发 `error` 类通知）。自动 hook 覆盖的是"停下/等你"这类高频事件，手动则覆盖一切你想主动推送的时刻。

## Flags 速查

| Flag | 作用 | 备注 |
|------|------|------|
| `--markdown` | 把 `<message>` 当 markdown 发（lark-cli 自动包成 post） | 默认是纯文本 `--text`。固定头 `## <emoji> <标题>\n\n` 会自动前置，**不可配置**；你的消息若也以 `#` 开头会出现两个相邻标题（预期 UX）。纯文本模式则原样拼接，不做归一化。 |
| `--dry-run` | 不发送，把本次解析出的完整 `lark-cli ...` 命令行打印到 stdout，exit 0 | 仍会校验参数（坏 type→exit 3）和配置（缺失/二义→exit 2），仍对 `progress` 跑节流检查（被节流则 exit 0 + stderr 提示 + **无** stdout 命令行，除非 `--force`）。打印的 `--idempotency-key` 是本次实时生成的，仅作示意；直接复用那行会重新生成新 key。 |
| `--force` | 仅对 `progress` 有意义：突破节流强制发送 | 其他 type 传入被忽略，不报错。 |
| `--help` / `-h` | 打印 usage 到 stdout，exit 0 | 优先级最高，覆盖一切。 |

## 四种 type 含义

| type | Emoji | 固定标题（中文） | 用途 |
|------|-------|------------------|------|
| `ask` | 🙋 | 需要你确认 | 需要用户交互/选择/决策 |
| `done` | ✅ | 任务完成 | agent 任务结束汇报 |
| `progress` | 📊 | 进度 | 长任务周期性 ping（默认节流 5 分钟） |
| `error` | ❌ | 出错了 | 任务失败/报错 |

## 非致命规则（必须遵守）

通知是锦上添花，**不是关键路径**。`notify.sh` 非零退出（包括收件人解析失败 exit 2、参数错误 exit 3、lark-cli 发送失败透传码）时：

- **不要阻塞主任务**，**不要重试**，**不要 abort**。
- 记一行日志即可，然后继续干活。
- 永远不要把 notify 调用包成「失败就停整个 agent」的形式。

错误信息会打到 stderr，exit 码透传 lark-cli 的（见下表）。主任务的成败只取决于主任务本身，不取决于这条通知能不能发出去。

## 退出码

| Code | 含义 | 调用方动作 |
|------|------|-----------|
| `0` | 成功发送 / progress 被节流 / `--dry-run` | 继续 |
| `2` | 收件人解析失败（没登录用户 / 两个收件人都配了） | 记一行，继续（非致命） |
| `3` | 参数错误（未知 type、缺 message 等） | 记一行，继续（调用方 bug） |
| 其他非零 | lark-cli 发送失败（透传 lark-cli exit 码） | 记一行，继续（非致命） |

## 前置条件

**收件人是可选的——默认发给你自己。** 只要 `lark-cli auth login` 过，不建 config.sh 就能用。`notify.sh` 解析收件人的顺序：

1. 配了 `RECIPIENT_USER_ID` → 发给该用户。
2. 否则配了 `RECIPIENT_CHAT_ID` → 发到该群。
3. 否则 → 解析当前登录用户（`lark-cli auth status` → `identities.user.openId`），发给你自己。
4. 解析失败（没登录 / 无用户身份）→ exit 2（非致命），stderr 提示 `lark-cli auth login`，不发。
5. 两个都配 = 二义 → exit 2。

默认发送身份 `AS=bot`，开箱即发（`auth login` 授予的 scope 足够）。

**设置步骤：**

1. 登录一次：`lark-cli auth login`（细节见 `lark-shared` skill）。
2. （可选）只有想发给别人/发到群，才拷贝配置模板并填一个收件人 ID（详见 README）：
   ```bash
   mkdir -p ~/.config/cc-alarm-larkcli
   cp ~/.claude/skills/cc-alarm-larkcli/config.example.sh ~/.config/cc-alarm-larkcli/config.sh
   # 编辑 config.sh：群 ID 用 lark-cli im +chat-search --query "<群名>" 或 +chat-list 查
   # 个人 ID 一般不用填（默认发给自己）。
   ```
3. 验证：`bash ~/.claude/skills/cc-alarm-larkcli/scripts/notify.sh done "测试"` 确认收到飞书消息。

完整安装/配置/故障排查见 [`README.md`](README.md)。

## References

- `lark-cli im +messages-send --help` — 本技能包装的底层命令。
- `lark-shared` skill — 认证、权限、scope 报错（41050 / Permission denied）、`--as user` vs `bot` 切换等通用排查。
