# cc-alarm-larkcli

给 Claude Code 子 agent 用的飞书通知小工具。一个 `notify.sh` 脚本 + 一份收件人配置，覆盖四种场景：任务完成（done）、需要确认（ask）、长任务进度（progress）、任务失败（error）。agent 在跑训练/编译/长任务时用它 ping 你，跑完汇报，卡住时找你拍板，失败时把错误推出来。

通知是锦上添花，**不是关键路径**：发送失败绝不阻塞主任务，记一行日志继续干。

## 安装

技能源在 `~/projects/cc-alarm-larkcli`，通过软链被 Claude Code 发现：

```bash
ln -s ~/projects/cc-alarm-larkcli ~/.claude/skills/cc-alarm-larkcli
```

> 源是 `~/projects/cc-alarm-larkcli`，软链只用于技能发现。所有改动回到项目目录里改，别改软链那一侧。

## 配置收件人（一次性）

`notify.sh` 会 `source ~/.config/cc-alarm-larkcli/config.sh`。没配每次都会 exit 2（非致命，但消息永远发不出）。

### 1. 拿到你的飞书 ID

用 `lark-cli`（先 `lark-cli auth login` 完成认证，见 `lark-shared` skill）：

```bash
# 你的个人 open_id（ou_xxx）—— 给自己发 DM
lark-cli contact +search-user --user-ids me --format json

# 某个群的 chat_id（oc_xxx）—— 发到群里
lark-cli im +chat-search --query "<群名>" --format json
# 或列出你所有群
lark-cli im +chat-list --format json
```

从输出里抓出 `ou_xxx` 或 `oc_xxx`。

### 2. 拷贝模板并填入

```bash
mkdir -p ~/.config/cc-alarm-larkcli
cp ~/projects/cc-alarm-larkcli/config.example.sh ~/.config/cc-alarm-larkcli/config.sh
# 编辑 config.sh
```

### 3. 配置变量说明

```sh
# 二选一：DM 一个用户，或发到一个群。两个都配 = 二义 = exit 2。
RECIPIENT_USER_ID="ou_xxx"   # 你的 open_id
# RECIPIENT_CHAT_ID="oc_xxx" # 群 chat_id（与上面互斥）

# 可选：身份。'user'（默认）或 'bot'。绝大多数场景用 user。
# AS="user"

# 可选：progress 节流秒数。默认 300（5 分钟）。
# THROTTLE_SECONDS=300
```

| 变量 | 必填 | 默认 | 含义 |
|------|------|------|------|
| `RECIPIENT_USER_ID` | 二选一 | — | `ou_xxx`，给这个用户发 DM。与 `RECIPIENT_CHAT_ID` 互斥。 |
| `RECIPIENT_CHAT_ID` | 二选一 | — | `oc_xxx`，发到这个群。与 `RECIPIENT_USER_ID` 互斥。 |
| `AS` | 否 | `user` | 传给 `lark-cli --as`，通常 `user`。 |
| `THROTTLE_SECONDS` | 否 | `300` | `progress` 两次发送最小间隔秒数，整数 ≥ 0。 |

### 4. 验证

真发一条，确认飞书收到：

```bash
bash ~/projects/cc-alarm-larkcli/scripts/notify.sh done "测试：cc-alarm-larkcli 配置完成"
```

收不到？看 stderr 提示 + 文末「故障排查」。

## 四种消息类型速查

| type | Emoji | 固定标题 | 用途 | 节流 |
|------|-------|---------|------|------|
| `ask` | 🙋 | 需要你确认 | 需要用户交互/决策 | 否（总是发） |
| `done` | ✅ | 任务完成 | 任务结束汇报 | 否（总是发） |
| `progress` | 📊 | 进度 | 长任务周期 ping | 是（默认 5 分钟，`--force` 突破） |
| `error` | ❌ | 出错了 | 任务失败 | 否（总是发） |

## Flags

| Flag | 作用 |
|------|------|
| `--markdown` | `<message>` 当 markdown 发（lark-cli 自动包成 post）。默认纯文本 `--text`。固定头 `## <emoji> <标题>\n\n` 会自动前置、不可配置；你的消息若也以 `#` 开头会出两个相邻标题（预期）。 |
| `--dry-run` | 不发送，打印本次解析出的完整 `lark-cli ...` 命令行到 stdout，exit 0。仍校验参数（坏 type→exit 3）和配置（缺失/二义→exit 2），仍对 `progress` 跑节流检查。打印的 `--idempotency-key` 是本次实时生成的，仅示意；复用那行会重新生成新 key。 |
| `--force` | 仅 `progress` 有效，突破节流强制发。其他 type 传入被忽略，不报错。 |
| `--help` / `-h` | 打印 usage，exit 0，优先级最高。 |

## 退出码

| Code | 含义 | 调用方动作 |
|------|------|-----------|
| `0` | 成功发送 / `progress` 被节流 / `--dry-run` | 继续 |
| `2` | 配置缺失或二义（收件人没配 / 两个都配了） | 记一行，继续（非致命） |
| `3` | 参数错误（未知 type、缺 message 等） | 记一行，继续（调用方 bug） |
| 其他非零 | lark-cli 发送失败（透传 lark-cli exit 码） | 记一行，继续（非致命） |

**非致命契约**：无论哪个非零码，都不要阻塞、不要重试、不要 abort 主任务。记一行日志，继续干。

## 目录结构

```
~/projects/cc-alarm-larkcli/
├── .claude-plugin/
│   └── plugin.json       # 插件 manifest，声明本目录是 @skills-dir 插件
├── hooks/
│   ├── hooks.json        # 插件自动 hook 注册表（Notification/Stop/SubagentStop）
│   └── hook-notify.sh    # hook 入口脚本，解析事件后调用 notify.sh
├── SKILL.md              # 技能发现 + 用法（agent 读这个）
├── README.md             # 本文件（人读这个）
├── config.example.sh     # 收件人配置模板，拷到 ~/.config/cc-alarm-larkcli/config.sh
└── scripts/
    └── notify.sh         # 唯一的执行入口（手动 + hook 共用）
```

## 插件与 Hook（自动通知）

本技能现在是一个 **`@skills-dir` 插件**：在项目根加了 `.claude-plugin/plugin.json`，顺着已有的软链 `~/.claude/skills/cc-alarm-larkcli → ~/projects/cc-alarm-larkcli`，Claude Code 启动时自动把它当本地插件加载。**零安装、无需 marketplace**——软链建好、Claude Code 启动即可用。

插件带 **3 个自动 hook**，在生命周期事件触发时直接调用 `notify.sh` 发飞书。这是"硬性/自动"的：agent 停下或等你输入时自动推送，**不依赖模型记得用 skill**。手动 `notify.sh` 调用（见上文「四种消息类型」）仍完全可用，适合 ad-hoc 自定义推送。

### Hook 事件映射

| Hook 事件 | 触发时机 | → notify.sh type | 正文来源 |
|---|---|---|---|
| `Notification` | agent 等你授权 / 空闲 | `ask` 🙋 | hook stdin 的 message（Claude Code 传入） |
| `Stop` | 主 agent 每轮结束 | `done` ✅ | 读本轮 transcript 最后 assistant 文本（截 200 字）；读不到则回退 "主 agent 一轮结束" |
| `SubagentStop` | 子 agent 完成 | `done` ✅ | 读 transcript 最后 assistant 文本；读不到则回退 "子 agent 完成" |

### 节流（防刷屏）

脚本内置节流，避免主 agent 每轮、子 agent 每次都刷屏：

| 变量（在 `~/.config/cc-alarm-larkcli/config.sh`） | 默认 | 含义 |
|---|---|---|
| `HOOK_THROTTLE_DONE` | `120` | `done`（Stop/SubagentStop）两次推送最小间隔秒数 |
| `HOOK_THROTTLE_ASK` | `60` | `ask`（Notification）两次推送最小间隔秒数 |

注意：手动 `progress` 调用用的是 `THROTTLE_SECONDS`（默认 300），与上面的 hook 节流是两套独立的配置项。

### 发送失败非致命

Hook 永远 `exit 0`、绝不阻塞 agent。lark-cli 没配好（`exit 2`）、网络抖动、或节流被触发，都只是静默不发，主任务照跑。这一点和手动调用的非致命契约一致。

### 激活步骤

**第一次安装或改了 `hooks/hooks.json` 后，必须重启 Claude Code 或执行 `/reload-plugins`**，hook 才会被注册生效。光建软链、改文件，不重启的话自动推送不工作。手动 `notify.sh` 不受影响，软链建好就能用。

### 如何关闭自动 hook

不想自动推送的话，最干净的办法是在插件层面禁用：移除或改名 `hooks/hooks.json`（或单条 hook 条目），再 `/reload-plugins`。手动 `notify.sh` 调用不受影响。

## 开发 / 本地测试

`--dry-run` 是主要测试手段（不发真消息）：

```bash
# 看本次会拼出什么 lark-cli 命令（body 单引号包裹，内部 ' 已转义）
bash scripts/notify.sh done "build ok" --dry-run
bash scripts/notify.sh progress "epoch 7/20" --markdown --dry-run

# 重置 progress 节流状态（节流文件里就一个 epoch 整数）
rm ~/.cache/cc-alarm-larkcli/last_progress
```

> `--dry-run` 输出里的 `--idempotency-key` 是本次实时生成的，复用那行命令会重新生成新 key——它不是可重跑的字面命令，只是「本次会发成这样」的示意。

## 故障排查

**每次都 exit 2（收件人没配置）**

stderr 会打印：

```
cc-alarm-larkcli: recipient not configured.
Create ~/.config/cc-alarm-larkcli/config.sh with exactly one of:
  RECIPIENT_USER_ID="ou_xxx"   # DM a user
  RECIPIENT_CHAT_ID="oc_xxx"   # send to a chat
See config.example.sh for the full template.
```

按提示把 `config.sh` 配好，二选一填 `ou_xxx` 或 `oc_xxx`。两个都填 = 二义 = 同样 exit 2。

**`progress` 老是不发（被节流）**

stderr 会提示 `progress throttled (last sent <N>s ago, min <THROTTLE_SECONDS>s; use --force to override)`。默认 5 分钟一次。要立即发就加 `--force`，或 `rm ~/.cache/cc-alarm-larkcli/last_progress` 重置节流状态。

**发送失败（非零退出，不是 2/3）**

stderr 会打印 `cc-alarm-larkcli: send failed (type=<type>, lark-cli exit <N>); <lark-cli 第一行 stderr>`。常见原因：

- 认证过期 → 跑 `lark-cli auth login`，细节见 `lark-shared` skill。
- 权限不足（41050 / Permission denied）→ 多半是 `--as user` 的可见范围问题，见 `lark-shared`。
- 收件人 ID 错了 → 重新 `+search-user --user-ids me` / `+chat-search` 确认。

不管哪种，**都是非致命**——主任务照跑，记一行继续。

## 局限

- **尽力而为、非致命**：发不出去不重试、不排队。lark-cli 的 idempotency key 只去重，不会重投。
- **单用户节流状态**：`~/.cache/cc-alarm-larkcli/last_progress` 就一个 epoch 整数，无文件锁。单 agent 流场景下足够；并发 `progress` 调用可能竞争读写（YAGNI，不处理）。
- **配置文件被 `source`**：`~/.config/cc-alarm-larkcli/config.sh` 是 shell 文件，会被执行。单用户工具，你拥有它，不是安全边界。
- **bash 必须**：shebang 是 `#!/usr/bin/env bash`，用了 `${RANDOM}`、indexed array。macOS 自带 `/bin/bash` 3.2 够用。别用 `sh` 跑。
