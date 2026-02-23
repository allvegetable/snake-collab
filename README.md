# snake-collab

`snake-collab.sh` 用于自动化 REX 写码 + MK2 审查循环。

## 功能

- 输入：任务描述、最大轮次（默认 3）、项目目录
- 每轮流程：
  1. REX (`codex exec`) 按任务/反馈修改代码
  2. MK2 (`claude -p --dangerously-skip-permissions`) 快速审查 `git diff --stat` + 关键 diff
  3. MK2 输出结构化结果：`STATUS`、`ISSUES`、`NEXT_TASK`
  4. `LGTM` 则结束；`NEEDS_WORK` 则进入下一轮修复
- 安全机制：
  - 最大轮次限制
  - 同一问题在首次出现后又连续重复 2 次自动升级退出（即累计 3 轮相同）
  - REX / MK2 单次调用默认 300 秒超时（可用 `SNAKE_COLLAB_TIMEOUT` 覆盖，单位秒）
  - MK2 缺少 `STATUS` 行时自动按 `NEEDS_WORK` 处理（不直接报错退出）
  - 会话 ID 带随机后缀，避免并发冲突
  - 每轮日志写入 `.collab/logs/`

## 依赖

请确保环境里有：

- `git`
- `codex`
- `claude`
- `timeout`
- `md5sum`

## 环境变量

### 给 REX (`codex`) 使用

必须提供：

- `OPENAI_API_KEY`
- `OPENAI_BASE_URL`

### 给 MK2 (`claude`) 使用

脚本内部会按要求注入：

- `ANTHROPIC_BASE_URL=https://your-anthropic-base-url`
- `ANTHROPIC_API_KEY=your-anthropic-api-key`
- `HTTPS_PROXY=http://your-proxy-address`

### 其他可选变量

- `SNAKE_COLLAB_TIMEOUT`：覆盖命令超时秒数（默认 `300`）

## 用法

### 位置参数

```bash
./snake-collab.sh "实现用户登录接口并补测试" 3 /path/to/project
```

参数顺序：

1. `task_description`（必填）
2. `max_rounds`（可选，默认 3）
3. `project_dir`（可选，默认当前目录）

### 命令参数

```bash
./snake-collab.sh -t "修复支付回调签名校验" -m 4 -p /path/to/project
```

## 输出与退出码

- 日志目录：`<project_dir>/.collab/logs/`
- 每轮产物：
  - `*.log`（总日志）
  - `*.rex.out` / `*.rex.err`
  - `*.mk2.out`

退出码：

- `0`：MK2 返回 `LGTM`
- `1`：参数/环境问题、工具失败、无变更等
- `2`：同一问题在首次出现后连续重复 2 次（升级退出）
- `3`：达到最大轮次仍未 `LGTM`

## 示例

```bash
export OPENAI_API_KEY="your-openai-key"
export OPENAI_BASE_URL="https://your-openai-compatible-endpoint"

./snake-collab.sh -t "为订单模块增加幂等保护并补充单测" -m 3 -p /home/yuhao/work/my-repo
```
