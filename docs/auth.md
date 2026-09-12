# 认证加固(密码策略与账号锁定)

> 密码复杂度策略与按账号的登录失败锁定。
> 对应代码:`src/modules/user/service.zig`(策略与锁定)、`src/modules/auth/api.zig`、`src/modules/user/api.zig`(错误映射)。

## 1. 密码策略

注册、修改密码、重置密码共用**同一个** `PasswordPolicy.validate`(通过 `setPassword` 这一唯一入口),避免各路径规则不一致。默认规则:

| 规则 | 默认 | 错误 |
| --- | --- | --- |
| 最小长度 | 10 | `PasswordTooShort` |
| 最大长度 | 128(限制哈希成本) | `PasswordTooLong` |
| 常见弱口令黑名单 | 内置约 70 条(含 `password123` 等) | `PasswordTooCommon` |
| 身份信息检查 | 不区分大小写,不得等于或包含邮箱本地部分/姓名(片段 < 3 字符忽略) | `PasswordContainsIdentity` |

API 层把每个错误映射为具体的 400 提示信息。

## 2. 账号锁定

- 进程内 `LoginLockout`(哈希表 + 互斥锁),按规范化邮箱计数。
- 默认:窗口 15 分钟内失败 5 次 → 锁定 15 分钟。
- 锁定检查在**数据库查询之前**,且对不存在的邮箱一视同仁 → 不构成用户枚举预言机。
- 登录成功清零计数;注册 / 改密 / 重置不查锁定(避免自锁)。

## 3. 可调参数

当前以结构体字段默认值形式内置(`LockoutConfig`、`PasswordPolicy`)。如需按环境调整,后续可接入环境变量(例如 `ZASDOOR_PASSWORD_MIN_LENGTH`、`ZASDOOR_LOCKOUT_MAX_FAILURES` / `ZASDOOR_LOCKOUT_WINDOW` / `ZASDOOR_LOCKOUT_COOLDOWN`)。

## 4. 部署注意

- 锁定状态是**进程内**的:多实例部署需要共享存储(如 Redis)才能全局生效;单实例自托管场景下工作正常。
- 与按 IP 的登录限流互补:限流挡单来源高频尝试,锁定挡针对某账号的慢速爆破。