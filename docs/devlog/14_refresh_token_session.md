# 14. 用 refresh token 管理用户会话

[12. Token 认证](./12_token_authentication.md) 已经把登录后的身份带到了后续请求里：登录成功后服务器签发一个 PASETO access token，客户端带着 `Authorization: Bearer <token>` 调受保护接口，中间件验签后取出 `username` 做授权。

但那一节末尾刻意留了一个伏笔：

> 但"无状态"也有代价：一个尚未过期的 token 一旦签发，服务器默认无法立刻撤销它。常见做法是让 access token 保持较短有效期，再配合 refresh token、撤销列表或密钥轮换。当前项目先实现有效期为 15 分钟的 access token。

15 分钟的 access token 意味着：用户每 15 分钟就要重新输入用户名和密码，体验极差。要么把 access token 的有效期拉长（损失安全性），要么补上"长期凭证 + 短期凭证"这套组合 —— 这一节做的就是后者。

## 短期 access token 和长期 refresh token

这套方案的核心是把"证明身份"和"调接口"两件事拆开：

- **access token**：短期凭证（15 分钟），每次调受保护接口都要带上。它在网络上传输频繁，所以有效期必须短。一旦泄露，攻击者最多在 15 分钟内冒用；
- **refresh token**：长期凭证（24 小时），只用来换新的 access token。它不会出现在普通业务请求里，传输次数远少于 access token，泄露面更小。

调用流程变成：

```text
登录
  → 返回 access token (15m) + refresh token (24h) + session_id
后续业务请求
  → 携带 access token
access token 过期
  → 调 /tokens/renew_access，发送 refresh token
  → 返回新的 access token (15m)
refresh token 也过期
  → 用户重新登录
```

更关键的区别是：access token 服务器**不存**，refresh token 服务器**要存**。

access token 无状态是为了横向扩容时不必查库。但 refresh token 一旦泄露，攻击者能在 24 小时内反复换新 access token —— 这才是真正危险的场景。所以服务器必须保留每个 refresh token 对应的 session 记录，并保留**主动废弃**它的能力。

只要服务端能查到对应 session，就能：

- 给可疑会话打 `is_blocked = true`，立刻让 refresh 失效；
- 在用户改密码 / 注销时清理所有 session；
- 审计某个 token 来自哪台机器、哪个 IP；
- 强制限制单个用户的活跃会话数。

## sessions 表

新增迁移 `db/migration/000003_add_sessions.up.sql`：

```sql
CREATE TABLE "sessions" (
  "id" uuid PRIMARY KEY,
  "username" varchar NOT NULL,
  "refresh_token" varchar NOT NULL,
  "user_agent" varchar NOT NULL,
  "client_ip" varchar NOT NULL,
  "is_blocked" boolean NOT NULL DEFAULT false,
  "expires_at" timestamptz NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT (now())
);

ALTER TABLE "sessions" ADD FOREIGN KEY ("username") REFERENCES "users" ("username");
```

几个字段背后的取舍：

- **`id` 使用 uuid，并且直接复用 refresh token payload 里的 `Payload.ID`**：[12 节](./12_token_authentication.md#统一-token-payload) 里 `Payload` 已经带了一个随机 `uuid.UUID`。让 session 主键就等于这个 UUID，客户端再次调 `/tokens/renew_access` 时，服务器只需要解码 refresh token、取出 `payload.ID`，就能 `GetSession(payload.ID)` 找回这条会话。不需要把 session_id 单独传来传去；
- **`user_agent` 和 `client_ip`**：登录那一刻的客户端指纹。后续在管理面板里能列出"这个账号现在有哪些活跃 session、分别来自哪台机器"，也方便人工排查异常登录；
- **`is_blocked`**：管理员或者用户主动注销时把它置 `true`。renew 时第一关就是判断这个标志位，比删行更轻量，也保留审计痕迹；

`db/query/session.sql` 提供两条最小查询：

```sql
-- name: CreateSession :one
INSERT INTO sessions (
  id,
  username,
  refresh_token,
  user_agent,
  client_ip,
  is_blocked,
  expires_at
) VALUES (
  $1, $2, $3, $4, $5, $6, $7
) RETURNING *;

-- name: GetSession :one
SELECT * FROM sessions
WHERE id = $1 LIMIT 1;
```

`sqlc generate` 之后，`db.Querier` 接口里多出 `CreateSession` 和 `GetSession` 两个方法，`mockdb.MockStore` 也跟着自动生成。这一套流程在 [02. 生成 CRUD 代码](./02_generate_crud.md) 里已经走过一遍，这次只是又加了一张表。

## 让 `CreateToken` 顺带返回 payload

写到这一步会撞到一个签名层面的问题：登录 handler 在签 refresh token 之后，需要拿到这个 token 的 `Payload.ID` 和 `Payload.ExpiredAt` 去建 session 记录、塞到响应里。但 12 节定下的 `Maker` 接口长这样：

```go
type Maker interface {
    CreateToken(username string, duration time.Duration) (string, error)
    VerifyToken(token string) (*Payload, error)
}
```

`CreateToken` 只吐 token 字符串，handler 拿到 token 之后要再调一次 `VerifyToken` 把 payload 解出来 —— 这等于把刚生成的 token 重新解一遍，纯粹做无用功。更直接的做法是把 payload 直接返回出来：

```go
type Maker interface {
    CreateToken(username string, duration time.Duration) (string, *Payload, error)
    VerifyToken(token string) (*Payload, error)
}
```

两个实现做对称修改。`JWTMaker`：

```go
func (maker *JWTMaker) CreateToken(username string, duration time.Duration) (string, *Payload, error) {
    payload, err := NewPayload(username, duration)
    if err != nil {
        return "", payload, err
    }

    jwtToken := jwt.NewWithClaims(jwt.SigningMethodHS256, payload)
    token, err := jwtToken.SignedString([]byte(maker.secretKey))
    return token, payload, err
}
```

`PasetoMaker` 同样把每一处 `return "", err` 改成 `return "", payload, err`，最终成功路径返回 `token, payload, nil`。

这是一个**破坏性的接口变更**，所有调用 `CreateToken` 的地方都要跟着改：

- `api/user.go` 的 `loginUser`；
- `token/jwt_maker_test.go` 和 `token/paseto_maker_test.go` 里所有的 `maker.CreateToken(...)`；
- `api/middleware_test.go` 里给请求添加 Authorization header 的 `addAuthorization` 辅助函数。

## 配置里加上 refresh token 有效期

`app.env`：

```env
TOKEN_SYMMETRIC_KEY=12345678901234567890123456789012
ACCESS_TOKEN_DURATION=15m
REFRESH_TOKEN_DURATION=24h
```

`util.Config` 对应加一个字段：

```go
type Config struct {
    DBDriver             string        `mapstructure:"DB_DRIVER"`
    DBSource             string        `mapstructure:"DB_SOURCE"`
    ServerAddress        string        `mapstructure:"SERVER_ADDRESS"`
    TokenSymmetricKey    string        `mapstructure:"TOKEN_SYMMETRIC_KEY"`
    AccessTokenDuration  time.Duration `mapstructure:"ACCESS_TOKEN_DURATION"`
    RefreshTokenDuration time.Duration `mapstructure:"REFRESH_TOKEN_DURATION"`
}
```

viper 把 `24h` 这种字符串自动解析成 `time.Duration`，这一段在 [07. 配置管理](./07_config_management.md) 已经介绍过。15 分钟 / 24 小时这组比例是常见经验值：足够长，让用户一天内不用反复登录；又足够短，让 refresh token 一旦泄露也只能用一天。

## 登录：签两把 token，落一条 session

`api/user.go` 里 `loginUserResponse` 从原来的两个字段扩成六个：

```go
type loginUserResponse struct {
    SessionID             uuid.UUID    `json:"session_id"`
    AccessToken           string       `json:"access_token"`
    AccessTokenExpiresAt  time.Time    `json:"access_token_expires_at"`
    RefreshToken          string       `json:"refresh_token"`
    RefreshTokenExpiresAt time.Time    `json:"refresh_token_expires_at"`
    User                  userResponse `json:"user"`
}
```

把两个 token 的过期时间也回写给客户端，是为了**让客户端不必自己解 token 就知道什么时候要续**。客户端只要看 `access_token_expires_at`，在到期前主动调 `/tokens/renew_access` 即可，不需要做 base64 解码、json 反序列化、字段映射这些和服务端实现绑死的事。

`SessionID` 单独抛出来也是同一思路：以后做"列出我所有会话 / 注销某个会话"的接口时，客户端可以直接拿这个 ID 用。

handler 在密码校验通过之后多了三段动作：签 access token、签 refresh token、写 session 表：

```go
accessToken, accessPayload, err := server.tokenMaker.CreateToken(
    user.Username,
    server.config.AccessTokenDuration,
)
if err != nil {
    ctx.JSON(http.StatusInternalServerError, errorResponse(err))
    return
}

refreshToken, refreshPayload, err := server.tokenMaker.CreateToken(
    user.Username,
    server.config.RefreshTokenDuration,
)
if err != nil {
    ctx.JSON(http.StatusInternalServerError, errorResponse(err))
    return
}

session, err := server.store.CreateSession(ctx, db.CreateSessionParams{
    ID:           refreshPayload.ID,
    Username:     user.Username,
    RefreshToken: refreshToken,
    UserAgent:    ctx.Request.UserAgent(),
    ClientIp:     ctx.ClientIP(),
    IsBlocked:    false,
    ExpiresAt:    refreshPayload.ExpiredAt,
})
if err != nil {
    ctx.JSON(http.StatusInternalServerError, errorResponse(err))
    return
}
```

- **`UserAgent` / `ClientIp` 从请求里直接抓**：Gin 的 `ctx.Request.UserAgent()` 读 `User-Agent` header，`ctx.ClientIP()` 会考虑反向代理设置的 `X-Forwarded-For` 等 header。客户端能伪造这两个值，所以它们只用于**事后审计**，而不是用于**事前判断**。

如果在签了 token 之后写 session 失败，handler 直接返回 500。这种情况下客户端拿不到 token，无害；服务端也没多余的状态需要清理（token 是无状态的，没写进去的 session 等于不存在）。这是一个朴素但安全的失败模式。

## `/tokens/renew_access`：用 refresh token 换新的 access token

`api/server.go` 把新路由挂在公开区，因为客户端调它时手里没有 access token：

```go
router.POST("/users", server.createUser)
router.POST("/users/login", server.loginUser)
router.POST("/tokens/renew_access", server.renewAccessToken)
```

handler 在 `api/token.go`，整体流程是"逐层把关，每关失败一种 401"：

```go
func (server *Server) renewAccessToken(ctx *gin.Context) {
    var req renewAccessTokenRequest
    if err := ctx.ShouldBindJSON(&req); err != nil {
        ctx.JSON(http.StatusBadRequest, errorResponse(err))
        return
    }

    refreshPayload, err := server.tokenMaker.VerifyToken(req.RefreshToken)
    if err != nil {
        ctx.JSON(http.StatusUnauthorized, errorResponse(err))
        return
    }

    session, err := server.store.GetSession(ctx, refreshPayload.ID)
    if err != nil {
        if err == sql.ErrNoRows {
            ctx.JSON(http.StatusNotFound, errorResponse(err))
            return
        }
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return
    }

    if session.IsBlocked {
        err := fmt.Errorf("blocked session")
        ctx.JSON(http.StatusUnauthorized, errorResponse(err))
        return
    }

    if session.Username != refreshPayload.Username {
        err := fmt.Errorf("incorrect session user")
        ctx.JSON(http.StatusUnauthorized, errorResponse(err))
        return
    }

    if session.RefreshToken != req.RefreshToken {
        err := fmt.Errorf("mismatched session token")
        ctx.JSON(http.StatusUnauthorized, errorResponse(err))
        return
    }

    accessToken, accessPayload, err := server.tokenMaker.CreateToken(
        refreshPayload.Username,
        server.config.AccessTokenDuration,
    )
    if err != nil {
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return
    }

    rsp := renewAccessTokenResponse{
        AccessToken:          accessToken,
        AccessTokenExpiresAt: accessPayload.ExpiredAt,
    }
    ctx.JSON(http.StatusOK, rsp)
}
```

每一道关卡分别拦截哪种攻击/异常：

| 关卡 | 在挡什么 |
| ---- | ---- |
| `VerifyToken` 失败 | refresh token 被篡改、签名错、已经过期 |
| `GetSession` 返回 `sql.ErrNoRows` | 这个 token 的 session 已经被删了，或者根本不是本系统签发的 |
| `session.IsBlocked` | 管理员/用户已经把这条会话拉黑 |
| `session.Username != refreshPayload.Username` | token 合法但和 session 对不上 —— 通常意味着密钥泄露后攻击者拿同一把密钥伪造了带不同 username 的 token |
| `session.RefreshToken != req.RefreshToken` | 客户端送来的 refresh token 不是这条 session 当初签发的那一份 |


`refreshPayload.ID` 和 `session.ID` 一样，只能证明"这两段字符串声称的 token ID 相同"。但 PASETO `v4.local` 用了随机 nonce，**同一个 payload、同一个对称密钥、不同 nonce 加密出来的密文是不同的**。所以两段 PASETO 密文哪怕解出来 payload 完全一致，它们也不是同一段 token。

如果只验签名 + 查 session，会出现一个尴尬情况：攻击者拿到密钥（不是 token），用同一个 username 自己签一段 PASETO token，再用任意旧 `payload.ID` 去碰运气 —— 如果运气好碰到一条还没过期的 session，他就能凭一段"自己伪造但 session 里能查到"的 token 换到合法 access token。

`session.RefreshToken != req.RefreshToken` 这一关把这个口子堵上：**只接受 session 表里存的那一份原文**。从攻击者视角看，要绕过这一关他必须同时拿到 session 表的 refresh_token 列（库被拖）和签名密钥（密钥泄露），门槛高很多。

## 暂时没做的几件事

renew 之后**不轮换 refresh token**：客户端拿到新 access token，refresh token 还是原来那串。这意味着这一份 refresh token 在 24 小时内会被反复使用。如果它泄露，攻击者就能在剩余有效期里持续刷新 access token。

业界更稳妥的做法叫 **refresh token rotation**：每次 renew 都签一个新的 refresh token，把旧的 `is_blocked = true`，让旧 token 立刻失效。配合"检测到旧 token 又被使用 → 把整个 user 的所有 session 拉黑"，可以在 token 被盗后第一时间感知。

token payload 里也没加 `token_type` 区分 access / refresh。意味着 refresh token 能直接当 access token 调业务接口。生产环境会在 `NewPayload` 里加一个枚举字段，中间件验签后断言它必须是 `access`，`renewAccessToken` 里断言必须是 `refresh`。

## 测试

`api/user_test.go` 补上 `TestLoginUserAPI`，覆盖 5 个分支：

| case | 期望 |
| ---- | ---- |
| `OK` | 200，store 期望调 `GetUser` 1 次、`CreateSession` 1 次 |
| `UserNotFound` | `GetUser` 返回 `sql.ErrNoRows` → 404 |
| `IncorrectPassword` | `GetUser` 返回正常用户，但请求密码错 → 401 |
| `InternalError` | `GetUser` 返回 `sql.ErrConnDone` → 500 |
| `InvalidUsername` | 用户名包含非法字符，连 `GetUser` 都不会被调用 → 400 |

最有信息量的是 `OK` 分支：

```go
store.EXPECT().
    GetUser(gomock.Any(), gomock.Eq(user.Username)).
    Times(1).
    Return(user, nil)
store.EXPECT().
    CreateSession(gomock.Any(), gomock.Any()).
    Times(1)
```

两条 `Times(1)` 把登录的"取用户 → 写会话"两步顺序钉死。`CreateSession` 这里 `gomock.Any()` 是因为入参里有 token 字符串、token payload UUID 这种每次都不同的值，断言它们没意义，关心的只是**这个调用确实发生了一次**。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `sessions` 表 | 给 refresh token 落一份服务端记录，让长期凭证可撤销、可审计 |
| `CreateSession` / `GetSession` | sqlc 生成的两条最小查询，配合 mock 走测试链路 |
| `RefreshTokenDuration` 配置 | 把"长期凭证多久过期"做成可调参数（24h）|
| `Maker.CreateToken` 签名变更 | 一次返回 token + payload，省掉登录 handler 再解一次 token |
| `loginUser` 双 token + 写 session | 登录一次拿到 access + refresh + session_id，并把客户端指纹落库 |
| `POST /tokens/renew_access` | 公开路由，验签 + 查 session + 比对原文，签出新的 access token |
| `session.RefreshToken` 原文比对 | 即便密钥泄露，伪造的同 ID token 也无法通过这一关 |
| `TestLoginUserAPI` | 覆盖登录的成功路径和四类失败分支，钉死调用顺序 |

到这里整套身份链路已经可以支撑真实使用了：用户登录一次能维持一天的活跃，而每次业务请求带的 access token 只活 15 分钟；中间任一环节出问题，服务端都有撤销的抓手。

