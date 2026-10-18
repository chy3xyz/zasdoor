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

- **持久化锁定**(表 `login_attempts`,键为规范化邮箱):计数在事务内做读改写,多实例部署共享同一份状态(不再是进程内哈希表)。
- 默认:窗口 15 分钟内失败 5 次 → 锁定 15 分钟。
- 锁定检查在**数据库查询之前**,且对不存在的邮箱一视同仁 → 不构成用户枚举预言机。
- 登录成功清零计数;注册 / 改密 / 重置不查锁定(避免自锁)。

## 3. 可调参数

当前以结构体字段默认值形式内置(`LockoutConfig`、`PasswordPolicy`)。如需按环境调整,后续可接入环境变量(例如 `ZASDOOR_PASSWORD_MIN_LENGTH`、`ZASDOOR_LOCKOUT_MAX_FAILURES` / `ZASDOOR_LOCKOUT_WINDOW` / `ZASDOOR_LOCKOUT_COOLDOWN`)。

## 4. 部署注意

- 锁定状态**落库**,多实例部署天然共享(`login_attempts` 表);读取/写入失败时 **fail-open**(记日志放行)以保可用性,不建议在强安全场景下依赖它单独兜底。
- 过期锁定行由定时任务 `login_attempts.prune`(24h)清理,防止随机邮箱把表撑大。
- 按 IP 的**限流仍是每实例内存**滑动计数:每请求落库会显著抬高开销,故未做共享存储;多实例部署应在网关/Ingress 统一限流,或后续接入 Redis 令牌桶。
- 与按 IP 的登录限流互补:限流挡单来源高频尝试,锁定挡针对某账号的慢速爆破。

## 5. 联邦账号(IdP)

- JIT 创建的联邦账号使用 `!federated` 占位密码,`verifyPassword` 恒定失败。
- **忘记密码**:不会为联邦账号生成重置 token(接口仍返回统一成功,防枚举)。
- **重置密码**:即使持有历史 token 也返回 `FederatedAccount`(HTTP 400 "该账号使用第三方登录,不支持密码重置"),避免绕过 IdP 获得本地密码。