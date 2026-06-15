# 12. Token 认证

[11. 密码存储](./11_store_password.md) 已经解决了注册和登录时的密码校验问题，但登录成功只代表服务器在**当前这一次请求**里确认了用户身份。HTTP 本身是无状态协议，下一次请求 `GET /accounts/1` 时，服务器不会自动记得这个请求来自谁。

这一节把身份信息带到后续请求里，并真正限制用户只能操作自己的账户

## 认证和授权不是一回事

这两个词经常一起出现，但解决的问题不同：

- **认证（Authentication）**：确认“你是谁”。例如用户名和密码校验成功后，确认请求者是 `alice`；
- **授权（Authorization）**：确认“你能做什么”。即使请求者确实是 `alice`，她也不能读取 `bob` 的账户或从 `bob` 的账户转账。

因此，请求受保护资源时要经过两层判断：

```text
请求携带 token
    ↓
验证 token，得到 username       ← 认证
    ↓
检查目标账户是否属于 username    ← 授权
    ↓
执行真正的业务逻辑
```

只做认证、不做资源归属校验仍然不安全：任何已登录用户都可能通过修改 URL 里的账户 ID 去访问别人的数据。

## 从 cookie + session 到 token

### cookie + session

传统 Web 应用通常使用 session 保存登录状态：

1. 用户提交用户名和密码；
2. 服务器校验成功后，创建一条 session 记录；
3. 服务器把随机生成的 `session_id` 放进响应 cookie；
4. 浏览器后续请求自动携带 cookie；
5. 服务器根据 `session_id` 查询 session，恢复用户身份。

这里 cookie 和 session 的职责不同：

- **cookie** 存在客户端，只负责携带一个 session 标识；
- **session** 存在服务端，保存这个标识对应的用户、过期时间等状态。

这种方式的优势是服务端掌握完整控制权：要让用户立刻下线，只要删除 session 即可。但它也意味着每次请求都要查询 session；当服务部署到多个实例时，还要让所有实例共享 session 存储，或者做 sticky session。

### token

token 方案把“用户是谁、什么时候过期”等信息编码到一段字符串里，并用密码学手段防止客户端篡改：

1. 用户登录成功；
2. 服务器签发 token，把 token 返回给客户端；
3. 客户端后续请求主动发送 `Authorization: Bearer <token>`；
4. 服务器验证 token 的真实性和有效期；
5. 验证成功后直接从 payload 取出用户名。

服务器不需要为每一个 access token 保存 session 记录，因此更容易横向扩容，也很适合 Web、移动端和第三方 API 使用。

但“无状态”也有代价：一个尚未过期的 token 一旦签发，服务器默认无法立刻撤销它。常见做法是让 access token 保持较短有效期，再配合 refresh token、撤销列表或密钥轮换。当前项目先实现有效期为 15 分钟的 access token。

| 对比项 | cookie + session | token |
| ---- | ---- | ---- |
| 身份状态存放位置 | session 在服务端 | 身份声明放在 token 中 |
| 每次请求是否查 session | 通常需要 | 通常不需要 |
| 多实例部署 | 需要共享 session 或 sticky session | 实例共享验证密钥即可 |
| 主动撤销 | 删除 session 即可 | 需要额外机制 |
| 常见使用场景 | 浏览器 Web 应用 | API、移动端、微服务 |

cookie 和 token 也不是互斥关系。token 仍然可以放进安全的 HttpOnly cookie；真正的区别是“服务端是否保存每次登录的会话状态”，而不是字符串放在哪个 HTTP 字段里。

## JWT 的签名和验签过程

JWT（JSON Web Token）是一种紧凑的 token 格式。一个 JWT 由三段 Base64URL 字符串组成，中间用 `.` 分隔：

```text
base64url(header).base64url(payload).base64url(signature)
```

例如 header 会声明 token 类型和签名算法：

```json
{
  "alg": "HS256",
  "typ": "JWT"
}
```

payload 保存业务声明：

```json
{
  "id": "7823eac5-7b93-4f29-a574-e43e135f2fb5",
  "username": "alice",
  "issued_at": "2026-05-29T10:00:00+08:00",
  "expired_at": "2026-05-29T10:15:00+08:00"
}
```

### JWT 的对称签名和验签

这一节使用 HS256，也就是 HMAC-SHA256。它是**对称签名**：签发方和验证方持有同一份 secret key。

签名过程可以写成：

```text
encodedHeader  = base64url(headerJSON)
encodedPayload = base64url(payloadJSON)
signingInput   = encodedHeader + "." + encodedPayload
signature      = HMAC-SHA256(secretKey, signingInput)

token = signingInput + "." + base64url(signature)
```

HMAC 会同时使用消息和 secret key 计算摘要。客户端即使能改 payload，也没有 secret key，无法为修改后的 `signingInput` 生成正确签名。

服务器收到 token 后：

1. 按 `.` 拆出 header、payload、signature；
2. 检查 header 声明的算法是不是允许的 `HS256`；
3. 用相同的 secret key 对前两段重新计算 HMAC-SHA256；
4. 用抗时序攻击的方式比较“重新计算的签名”和“token 自带的签名”；
5. 签名一致后，再检查 `expired_at` 等声明；
6. 全部通过后，才信任 payload 里的 `username`。

这里有两个必须注意的边界：

- **JWT 默认不加密 payload**：前两段只是 Base64URL 编码，任何拿到 token 的人都能解码阅读。不能把密码、银行卡号等秘密放进去；
- **不能盲信 header 里的 `alg`**：攻击者可以自行修改 header。验证端必须主动限制允许的算法，否则可能遭受 `alg: none` 或算法混淆攻击。

签名保证的是**完整性和来源真实性**，不是保密性。

### JWT 的非对称签名和验签

JWT 也支持非对称签名，例如 `RS256`、`ES256` 和 `EdDSA`。它们使用一对密钥：

- 私钥只由签发方保管，用来生成签名；
- 公钥可以分发给其他服务，只能用来验证签名。

以 `RS256` 为例，header 中的 `alg` 改为 `RS256`，header 和 payload 的编码方式保持不变：

```text
encodedHeader  = base64url(headerJSON)
encodedPayload = base64url(payloadJSON)
signingInput   = encodedHeader + "." + encodedPayload

signature = RSA-SHA256-Sign(privateKey, signingInput)
token = signingInput + "." + base64url(signature)
```

验证方收到 token 后，用签发方公开的公钥验证签名：

```text
RSA-SHA256-Verify(publicKey, signingInput, signature)
```

验证成功说明 token 确实由对应私钥的持有者签发，并且 header 和 payload 没有被修改。与 HS256 不同，持有公钥的服务只能验签，不能生成有效签名。因此，一个认证服务可以独占私钥，其他 API 服务只保存公钥。

非对称签名同样不会加密 payload。任何拿到 JWT 的人仍然可以读取 header 和 payload，只是无法在修改后生成有效签名。

## PASETO 的加密和验证过程

PASETO（Platform-Agnostic Security Tokens）和 JWT 的目标相似，但它刻意减少算法选择，把安全算法绑定到版本和用途上，避免应用在大量组合里选错。

PASETO token 的开头会直接表明版本和用途：

```text
v4.local.<encoded body>
v4.public.<encoded body>
```

- `local` 是“仅供一组彼此信任的服务在内部使用”的对称密钥模式；
- `public` 是“签发方签名，其他服务公开验证”的非对称密钥模式。

### `local` 和 `public` 分别解决什么问题

`local` 使用一把共享的对称密钥。持有这把密钥的服务既能生成 token，也能解密和验证 token：

```text
认证服务 ── shared secret ── API 服务
             │
             ├── 可以签发
             ├── 可以解密
             └── 可以验证
```

它适合单体应用，或者少量完全互信的内部服务。既然所有验证方都已经被允许持有同一份密钥，那么顺便用这把密钥加密 payload，可以同时获得：

- **保密性**：没有密钥的人看不到 payload；
- **完整性**：攻击者无法悄悄修改 payload；
- **真实性**：能生成有效 token 的人必然持有共享密钥。

代价是权限无法拆开：任何可以验证 `local` token 的服务，也拥有生成 token 的能力。如果某个边缘服务泄露共享密钥，攻击者就能伪造整个系统接受的 token。

`public` 使用一对非对称密钥：

```text
认证服务持有私钥                       API / 第三方服务持有公钥
      │                                        │
      └── 私钥签名 token ─────────────────────→ └── 公钥验签
```

只有私钥持有者能签发 token，公钥可以分发给任意验证方。即使某个只负责验签的服务被攻破，攻击者拿到公钥也无法伪造 token。因此它适合：

- 一个认证中心给许多微服务签发 token；
- token 需要交给不应拥有签发权限的第三方验证；
- 希望公开发布验证公钥。

`public` 的目标是**可公开验证的真实性**，不是保密性，所以 payload 会保持明文可读，只由签名防止篡改。如果业务还要求隐藏 payload，通常应在传输层使用 TLS，或者另外采用面向接收方的加密协议。PASETO 不把“任何人都能验证”和“只有特定接收者能解密”强行混进同一个 `public` 用途里。

当前项目使用的是 **`v4.local`**。因此严格来说，它不是“签名后验签”，而是“认证加密后解密并验证”。服务端持有一把 32 字节对称密钥。

### 先认识 PASETO 里的几个组成部分

#### Footer：随 token 明文携带的受保护元数据

PASETO 可以在 token 最后附加一段可选 footer：

```text
v4.local.<encoded body>.<encoded footer>
```

footer **不会被加密**，拿到 token 的人可以直接读取；但它会参与 MAC 或签名计算，因此验证成功后可以确认 footer 没有被篡改。

它适合放“验证 token 前就需要知道、但不需要保密”的元数据，最常见的是密钥 ID：

```json
{"kid":"auth-key-2026-05"}
```

验证服务可以先读取 `kid`，选择对应的历史密钥，再验证 token。这在密钥轮换时很有用。需要注意，验证前读到的 footer 仍然是不可信输入，只能用于选择候选密钥；必须等整个 token 验证成功后，才能真正信任 footer。

当前项目不需要密钥轮换，所以 footer 传 `nil`。

#### Nonce：让同一份明文每次产生不同密文的一次性随机数

nonce 可以理解成“number used once”。它不是密钥，也不需要保密，而是每次加密时生成的一次性随机值。

如果只用固定密钥加密，而没有 nonce，同一个用户在相同时间字段下生成的相同 payload 可能产生相同密文，观察者就能判断两个 token 的内容相同。`v4.local` 每次生成 32 字节随机 nonce，再用“主密钥 + nonce”派生本次消息专用的加密密钥、认证密钥和 24 字节 ChaCha20 nonce。这样即使 payload 相同，生成的 token 也不同。

nonce 会被放进 token body，验证方需要用它重新派生同一组临时密钥。它的安全要求是每次加密都足够随机、不能被攻击者控制；PASETO 库负责生成，业务代码不需要自己处理。

#### Implicit assertion：参与验证、但不写进 token 的外部上下文

implicit assertion 是一段**不会出现在最终 token 中**的额外数据，但它会参与 MAC 或签名计算。签发方和验证方必须从外部提供完全相同的值，否则验证失败。

例如，同一把密钥可能服务多个租户，可以把租户 ID 作为 implicit assertion：

```text
implicit = "tenant:bank-a"
```

即使一个属于 `bank-a` 的 token 被拿到 `bank-b` 环境里，token 字符串本身完全没变，仍会因为验证方提供的 implicit assertion 不同而失败。它相当于把 token 密码学地绑定到某个外部上下文，同时不把这个上下文公开写进 token。

implicit assertion 不能从 token 中恢复，也不会自动传输。签发方和验证方必须事先约定如何得到它。当前项目没有这种上下文绑定需求，所以传 `nil`。

#### PAE：给多段数据划清边界

PAE（Pre-Authentication Encoding）是一种在计算 MAC 或签名前使用的**无歧义编码方式**。

假设直接把两段数据拼接：

```text
"ab" + "c"  = "abc"
"a"  + "bc" = "abc"
```

拼接结果相同，但原始字段划分不同。PAE 会把“总共有几段、每段多长、每段内容是什么”一起编码：

```text
PAE(piece1, piece2, ...)
    = piece_count
    || length(piece1) || piece1
    || length(piece2) || piece2
    || ...
```

因此 `PAE("ab", "c")` 和 `PAE("a", "bc")` 一定不同。PASETO 把 header、nonce、密文、footer、implicit assertion 分段做 PAE，再对结果计算 MAC 或签名，保证每一部分的边界和顺序都受到保护。

#### Tag：证明密文和相关元数据没有被修改的认证标签

`v4.local` 的 tag 是一个 32 字节 MAC（Message Authentication Code）。它由认证密钥和 PAE 后的数据计算得出：

```text
tag = keyed-BLAKE2b(authKey, PAE(...))
```

### `v4.local` 怎么生成 token

现在再看 `v4.local` 的生成过程：

1. 把 `Payload` 序列化为 JSON；
2. 生成一个 32 字节随机 nonce；
3. 从对称主密钥和 nonce 派生本次消息使用的加密密钥 `encKey`、认证密钥 `authKey` 和 24 字节加密 nonce；
4. 使用 ChaCha20 加密 payload，得到密文；
5. 把固定 header、nonce、密文、footer 和 implicit assertion 做 PAE（Pre-Authentication Encoding）；
6. 使用 `authKey` 对 PAE 结果计算 keyed BLAKE2b，得到 tag；
7. 把 nonce、密文和 tag 编码进 token body，并在末尾附上可选 footer。

可以抽象成：

```text
header = "v4.local."
nonce  = random()

encKey, authKey, encNonce = derive(masterKey, nonce)
ciphertext = ChaCha20(encKey, encNonce, payloadJSON)
tag = keyed-BLAKE2b(authKey, PAE(header, nonce, ciphertext, footer, implicit))

token = header + base64url(nonce || ciphertext || tag) + optionalFooter
```

这里 footer 虽然在 body 外明文携带，仍然被 tag 保护；implicit assertion 虽然不在 token 中，也被 tag 绑定。

### `v4.local` 怎么验证

验证过程与生成过程相反：

1. 确认 token 的 header 是 `v4.local.`；
2. 解码并取出 nonce、密文和认证标签；
3. 用相同主密钥和 nonce 派生加密密钥、认证密钥和加密 nonce；
4. 重新计算认证标签并安全比较；
5. 标签一致后才解密密文；
6. 反序列化 payload

任何人只要修改 header、密文、footer 或认证标签中的任意一位，验证都会失败。与当前 JWT 实现相比，`v4.local` 还隐藏了 payload 内容。

### `v4.public` 怎么签名和验签

`v4.public` 的过程比 `local` 更接近 JWT。

`v4.public` 使用 Ed25519 非对称签名。签发方保管私钥，验证方只需要公钥。生成 token 时：

1. 把 payload 序列化，但**不加密**；
2. 对 header、payload、footer 和 implicit assertion 做 PAE；
3. 使用 Ed25519 私钥对 PAE 结果签名；
4. 把明文 payload 和签名一起编码进 token body，再附上可选 footer。

```text
header = "v4.public."
message = PAE(header, payloadJSON, footer, implicit)
signature = Ed25519-Sign(privateKey, message)

token = header + base64url(payloadJSON || signature) + optionalFooter
```

验证方收到 token 后：

1. 确认 header 是 `v4.public.`；
2. 从 body 里拆出明文 payload 和签名；
3. 使用同样的 header、payload、footer 和外部提供的 implicit assertion 重建 PAE；
4. 用公钥验证 Ed25519 签名；
5. 签名通过后，再检查 payload 中的过期时间和业务声明。

任何人都能读取 `public` token 的 payload，但只有私钥持有者能生成有效签名。footer 和 implicit assertion 的作用与 `local` 相同：footer 明文随 token 携带，implicit assertion 不写入 token；两者都会受到签名保护。

## 统一 token payload

JWT 和 PASETO 的外层格式不同，但业务层真正关心的数据相同。新建 `token/payload.go`：

```go
type Payload struct {
    ID        uuid.UUID `json:"id"`
    Username  string    `json:"username"`
    IssuedAt  time.Time `json:"issued_at"`
    ExpiredAt time.Time `json:"expired_at"`
}

func NewPayload(username string, duration time.Duration) (*Payload, error) {
    tokenID, err := uuid.NewRandom()
    if err != nil {
        return nil, err
    }

    now := time.Now()
    payload := &Payload{
        ID:        tokenID,
        Username:  username,
        IssuedAt:  now,
        ExpiredAt: now.Add(duration),
    }

    return payload, nil
}
```

四个字段各有明确用途：

| 字段 | 用途 |
| ---- | ---- |
| `ID` | 每个 token 唯一，后续可以用于审计或撤销列表 |
| `Username` | 标识当前登录用户，后续授权规则靠它判断资源归属 |
| `IssuedAt` | token 签发时间 |
| `ExpiredAt` | token 失效时间 |

`Payload` 同时还实现了 `jwt.Claims` 接口：

```go
var _ jwt.Claims = (*Payload)(nil)

func (payload *Payload) GetExpirationTime() (*jwt.NumericDate, error) {
    return &jwt.NumericDate{Time: payload.ExpiredAt}, nil
}

func (payload *Payload) GetIssuedAt() (*jwt.NumericDate, error) {
    return &jwt.NumericDate{Time: payload.IssuedAt}, nil
}

func (payload *Payload) GetNotBefore() (*jwt.NumericDate, error) {
    return &jwt.NumericDate{Time: payload.IssuedAt}, nil
}
```

`golang-jwt` 在验签后会通过这些方法读取过期时间、签发时间和生效时间。`GetNotBefore` 返回 `IssuedAt`，表示 token 从签发时刻开始生效。issuer、subject、audience 当前没有业务需求，对应方法返回空值即可。

## 用 `Maker` 隔离 JWT 和 PASETO

新建 `token/maker.go`：

```go
type Maker interface {
    CreateToken(username string, duration time.Duration) (string, error)
    VerifyToken(token string) (*Payload, error)
}
```

API 层只依赖这两个动作：

- 登录成功后调用 `CreateToken`；
- 鉴权中间件调用 `VerifyToken`。

它不需要知道底层使用 JWT 还是 PASETO。以后切换实现时，只要在构造 `Server` 的地方换一个 maker，登录和中间件都不用改。

## 实现 JWT maker

`token/jwt_maker.go`：

```go
const minSecretKeySize = 32

type JWTMaker struct {
    secretKey string
}

func NewJWTMaker(secretKey string) (Maker, error) {
    if len(secretKey) < minSecretKeySize {
        return nil, fmt.Errorf(
            "invalid key size: must be at least %d characters",
            minSecretKeySize,
        )
    }
    return &JWTMaker{secretKey}, nil
}
```

HS256 的安全性依赖 secret key。这里通过 Go 的 `len` 要求至少 32 字节，避免使用过短、容易被暴力破解的密钥。

### 签发 JWT

```go
func (maker *JWTMaker) CreateToken(
    username string,
    duration time.Duration,
) (string, error) {
    payload, err := NewPayload(username, duration)
    if err != nil {
        return "", err
    }

    jwtToken := jwt.NewWithClaims(jwt.SigningMethodHS256, payload)
    return jwtToken.SignedString([]byte(maker.secretKey))
}
```

`NewWithClaims` 生成 header 和 payload，`SignedString` 再使用 secret key 完成 HS256 签名。

### 验证 JWT

```go
func (maker *JWTMaker) VerifyToken(token string) (*Payload, error) {
    jwtToken, err := jwt.ParseWithClaims(
        token,
        &Payload{},
        func(t *jwt.Token) (any, error) {
            return []byte(maker.secretKey), nil
        },
        jwt.WithExpirationRequired(),
        jwt.WithValidMethods([]string{jwt.SigningMethodHS256.Name}),
    )
    if err != nil {
        return nil, err
    }

    payload, ok := jwtToken.Claims.(*Payload)
    if !ok {
        return nil, jwt.ErrTokenInvalidClaims
    }
    return payload, nil
}
```

`ParseWithClaims` 的第三个参数是一个 `jwt.Keyfunc`。这里用匿名函数实现它：

```go
func(t *jwt.Token) (any, error) {
    return []byte(maker.secretKey), nil
}
```

解析器不自己知道应该用哪把密钥验签，因此它解析出 JWT header 后，会调用这个函数向业务代码索要验证密钥。

参数 `t *jwt.Token` 是正在验证的 token。此时解析器已经读取了 header，因此回调可以通过 `t.Method` 等信息判断应该返回哪把密钥，但 token 还没有完成验签，不能信任它携带的任何业务数据。

当前项目只使用一把 HS256 对称密钥，所以回调直接返回 `maker.secretKey` 的字节形式。在需要密钥轮换的系统中，header 通常还会包含 `kid`。`Keyfunc` 可以根据 `kid` 从多把候选密钥中选择一把：

```go
func(t *jwt.Token) (any, error) {
    kid, ok := t.Header["kid"].(string)
    if !ok {
        return nil, errors.New("missing key id")
    }
    return keys[kid], nil
}
```

这里两项 parser option 很关键：

- `jwt.WithExpirationRequired()`：token 必须包含可读取的过期时间，不能签发一个永不过期的 JWT；
- `jwt.WithValidMethods([]string{"HS256"})`：验证端只接受 HS256，不能让 token header 自己决定验证算法。

`jwt.Keyfunc` 负责回答“**用哪把密钥验证**”，`WithValidMethods` 负责限制“**允许使用什么算法验证**”。

## 实现 PASETO maker

`token/paseto_maker.go` 使用 `aidanwoods.dev/go-paseto`：

```go
type PasetoMaker struct {
    symmetricKey paseto.V4SymmetricKey
}

func NewPasetoMaker(symmetricKey string) (Maker, error) {
    key, err := paseto.V4SymmetricKeyFromBytes([]byte(symmetricKey))
    if err != nil {
        return nil, err
    }

    return &PasetoMaker{key}, nil
}
```

`V4SymmetricKeyFromBytes` 要求输入正好是 32 字节。与 JWT maker 的“至少 32 字符”相比，这里的长度要求更严格。

### 加密 PASETO

```go
func (maker *PasetoMaker) CreateToken(
    username string,
    duration time.Duration,
) (string, error) {
    payload, err := NewPayload(username, duration)
    if err != nil {
        return "", err
    }

    claimsData, err := json.Marshal(*payload)
    if err != nil {
        return "", err
    }

    pasetoToken, err := paseto.NewTokenFromClaimsJSON(claimsData, nil)
    if err != nil {
        return "", err
    }
    return pasetoToken.V4Encrypt(maker.symmetricKey, nil), nil
}
```

这里先把统一的 `Payload` 序列化成 JSON claims，再交给 `V4Encrypt` 生成 `v4.local` token。两个 `nil` 分别表示当前没有 footer 和 implicit assertion。

### 解密并验证 PASETO

```go
func (maker *PasetoMaker) VerifyToken(token string) (*Payload, error) {
    parser := paseto.NewParserWithoutExpiryCheck()
    pasetoToken, err := parser.ParseV4Local(maker.symmetricKey, token, nil)
    if err != nil {
        return nil, err
    }

    payload := &Payload{}
    if err = json.Unmarshal(pasetoToken.ClaimsJSON(), payload); err != nil {
        return nil, err
    }

    if time.Now().After(payload.ExpiredAt) {
        return nil, fmt.Errorf("token has expired")
    }

    return payload, nil
}
```

当前 payload 使用自定义字段 `expired_at`，因此 parser 只负责验证并解密 token，过期时间由代码显式检查。只有 `ParseV4Local` 验证通过后，程序才会反序列化并信任 claims。

## 测试两种 token 实现

JWT 和 PASETO 都要验证“正常 token 可还原”和“过期 token 被拒绝”：

```go
func TestPasetoMaker(t *testing.T) {
    maker, err := NewPasetoMaker(util.RandomString(32))
    require.NoError(t, err)

    username := util.RandomOwner()
    duration := time.Minute
    issuedAt := time.Now()
    expiredAt := issuedAt.Add(duration)

    token, err := maker.CreateToken(username, duration)
    require.NoError(t, err)
    require.NotEmpty(t, token)

    payload, err := maker.VerifyToken(token)
    require.NoError(t, err)

    require.NotZero(t, payload.ID)
    require.Equal(t, username, payload.Username)
    require.WithinDuration(t, issuedAt, payload.IssuedAt, time.Second)
    require.WithinDuration(t, expiredAt, payload.ExpiredAt, time.Second)
}
```

时间断言继续使用 `WithinDuration`，避免签发 token 前后几行代码消耗的时间让测试出现纳秒级误差。

JWT 还专门构造了一个 `alg: none` token：

```go
func TestInvalidJWTTokenAlgNone(t *testing.T) {
    payload, err := NewPayload(util.RandomOwner(), time.Minute)
    require.NoError(t, err)

    jwtToken := jwt.NewWithClaims(jwt.SigningMethodNone, payload)
    token, err := jwtToken.SignedString(jwt.UnsafeAllowNoneSignatureType)
    require.NoError(t, err)

    maker, err := NewJWTMaker(util.RandomString(32))
    require.NoError(t, err)

    payload, err = maker.VerifyToken(token)
    require.Error(t, err)
    require.Nil(t, payload)
}
```

这条测试钉死了 `WithValidMethods` 的安全边界：即使攻击者能构造一个结构合法的无签名 JWT，maker 也必须拒绝。

## 登录成功后签发 token

先在配置里加入对称密钥和 access token 有效期：

```env
TOKEN_SYMMETRIC_KEY=12345678901234567890123456789012
ACCESS_TOKEN_DURATION=15m
```

`util.Config` 对应增加：

```go
type Config struct {
    DBDriver            string        `mapstructure:"DB_DRIVER"`
    DBSource            string        `mapstructure:"DB_SOURCE"`
    ServerAddress       string        `mapstructure:"SERVER_ADDRESS"`
    TokenSymmetricKey   string        `mapstructure:"TOKEN_SYMMETRIC_KEY"`
    AccessTokenDuration time.Duration `mapstructure:"ACCESS_TOKEN_DURATION"`
}
```

然后让 `Server` 持有配置和 token maker：

```go
type Server struct {
    config     util.Config
    store      db.Store
    tokenMaker token.Maker
    router     *gin.Engine
}

func NewServer(config util.Config, store db.Store) (*Server, error) {
    tokenMaker, err := token.NewPasetoMaker(config.TokenSymmetricKey)
    if err != nil {
        return nil, fmt.Errorf("cannot create token maker: %w", err)
    }

    server := &Server{
        config:     config,
        store:      store,
        tokenMaker: tokenMaker,
    }
    // ...
    return server, nil
}
```

项目同时实现了 JWT 和 PASETO，但服务器当前选择 `PasetoMaker`。由于 handler 只依赖 `token.Maker`，切换成 `NewJWTMaker` 不会影响下面的登录和鉴权逻辑。

### `POST /users/login`

`api/user.go` 新增登录接口：

```go
type loginUserRequest struct {
    Username string `json:"username" binding:"required,alphanum"`
    Password string `json:"password" binding:"required,min=6"`
}

type loginUserResponse struct {
    AccessToken string       `json:"access_token"`
    User        userResponse `json:"user"`
}
```

handler 的流程是：

```go
func (server *Server) loginUser(ctx *gin.Context) {
    var req loginUserRequest
    if err := ctx.ShouldBindJSON(&req); err != nil {
        ctx.JSON(http.StatusBadRequest, errorResponse(err))
        return
    }

    user, err := server.store.GetUser(ctx, req.Username)
    if err != nil {
        if err == sql.ErrNoRows {
            ctx.JSON(http.StatusNotFound, errorResponse(err))
            return
        }
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return
    }

    if err = util.CheckPassword(req.Password, user.HashedPassword); err != nil {
        ctx.JSON(http.StatusUnauthorized, errorResponse(err))
        return
    }

    accessToken, err := server.tokenMaker.CreateToken(
        user.Username,
        server.config.AccessTokenDuration,
    )
    if err != nil {
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return
    }

    rsp := loginUserResponse{
        AccessToken: accessToken,
        User:        newUserResponse(user),
    }
    ctx.JSON(http.StatusOK, rsp)
}
```

只有用户名存在且密码校验成功后才会签发 token。响应里的用户信息继续使用 `userResponse`，不会泄露 `HashedPassword`。

最后注册公开路由：

```go
router.POST("/users", server.createUser)
router.POST("/users/login", server.loginUser)
```

注册和登录必须保持公开，否则还没有 token 的新用户永远无法进入系统。

## Gin 中间件是怎么工作的

Gin 的 handler 本质上会组成一条调用链。中间件也是 `gin.HandlerFunc`，它可以在真正的业务 handler 前后执行逻辑：

```text
request
  → logger middleware
  → recovery middleware
  → auth middleware
  → business handler
  → response
```

中间件里常用的三个动作：

- `ctx.Next()`：继续执行调用链后面的 handler；
- `ctx.Abort()` / `ctx.AbortWithStatusJSON(...)`：终止后续 handler；
- `ctx.Set(key, value)`：往当前请求的 context 放数据，后面的 handler 可以读取。

鉴权逻辑适合放进中间件，因为每个受保护接口都需要执行同一套“取 header、验 token、恢复用户身份”的流程。

## 实现鉴权中间件

客户端按 Bearer 规范发送 token：

```http
Authorization: Bearer v4.local....
```

`api/middleware.go`：

```go
const (
    authorizationHeaderKey  = "authorization"
    authorizationTypeBearer = "bearer"
    authorizationPayloadKey = "authorization_payload"
)

func authMiddleware(tokenMaker token.Maker) gin.HandlerFunc {
    return func(ctx *gin.Context) {
        authorizationHeader := ctx.GetHeader(authorizationHeaderKey)
        if len(authorizationHeader) == 0 {
            err := errors.New("authorization header is not provided")
            ctx.AbortWithStatusJSON(http.StatusUnauthorized, errorResponse(err))
            return
        }

        fields := strings.Fields(authorizationHeader)
        if len(fields) < 2 {
            err := errors.New("invalid authorization header format")
            ctx.AbortWithStatusJSON(http.StatusUnauthorized, errorResponse(err))
            return
        }

        authorizationType := strings.ToLower(fields[0])
        if authorizationType != authorizationTypeBearer {
            err := fmt.Errorf(
                "unsupported authorization type %s",
                authorizationType,
            )
            ctx.AbortWithStatusJSON(http.StatusUnauthorized, errorResponse(err))
            return
        }

        payload, err := tokenMaker.VerifyToken(fields[1])
        if err != nil {
            ctx.AbortWithStatusJSON(http.StatusUnauthorized, errorResponse(err))
            return
        }

        ctx.Set(authorizationPayloadKey, payload)
        ctx.Next()
    }
}
```

中间件依次拒绝四类请求：

| 情况 | 处理 |
| ---- | ---- |
| 没有 `Authorization` header | 返回 401 |
| header 无法拆出类型和 token | 返回 401 |
| 类型不是 `Bearer` | 返回 401 |
| token 无效、被篡改或已过期 | 返回 401 |

验证通过后，payload 会放进当前请求的 Gin context。业务 handler 不需要再次解析 token，只要读取 `authorization_payload` 即可。

### 只给受保护路由挂中间件

```go
router.POST("/users", server.createUser)
router.POST("/users/login", server.loginUser)

authRoutes := router.Group("/", authMiddleware(server.tokenMaker))

authRoutes.POST("/accounts", server.createAccount)
authRoutes.GET("/accounts/:id", server.getAccount)
authRoutes.GET("/accounts", server.listAccounts)
authRoutes.POST("/transfers", server.createTransfer)
```

Gin 的 route group 可以给一组路由统一挂中间件。这样公开接口和受保护接口的边界一眼就能看出来，也避免每个路由重复写 `authMiddleware(...)`。

## 在 handler 里补上授权规则

中间件只确认 token 合法，并把 `Username` 传给后续 handler。接下来要用这个用户名限制具体资源。

### 创建账户：owner 只能来自 token

以前创建账户时，客户端可以在 JSON 里自行提交 `owner`。这意味着登录用户可以把账户建到任何用户名下。现在请求体只接收币种：

```go
type createAccountRequest struct {
    Currency string `json:"currency" binding:"required,currency"`
}

authPayload := ctx.MustGet(authorizationPayloadKey).(*token.Payload)
arg := db.CreateAccountParams{
    Owner:    authPayload.Username,
    Currency: req.Currency,
    Balance:  0,
}
```

`Owner` 由服务端从已验证 payload 中取得，客户端没有伪造空间。

### 查询单个账户：检查 owner

```go
authPayload := ctx.MustGet(authorizationPayloadKey).(*token.Payload)
if account.Owner != authPayload.Username {
    err := errors.New("account doesn't belong to the authenticated user")
    ctx.JSON(http.StatusUnauthorized, errorResponse(err))
    return
}
```

即使用户猜到了别人的账户 ID，也会因为 owner 不匹配被拒绝。

### 查询账户列表：从 SQL 层限制 owner

列表查询不能先取出所有账户再在 Go 里过滤，否则既浪费资源，也容易在后续改动里泄露数据。直接修改 SQL：

```sql
-- name: ListAccounts :many
SELECT * FROM accounts
WHERE owner = $1
ORDER BY id
LIMIT $2
OFFSET $3;
```

handler 把 token 里的用户名传给查询：

```go
authPayload := ctx.MustGet(authorizationPayloadKey).(*token.Payload)
arg := db.ListAccountsParams{
    Owner:  authPayload.Username,
    Limit:  req.PageSize,
    Offset: (req.PageID - 1) * req.PageSize,
}
```

这样数据库只会返回当前用户的账户。

### 转账：只能从自己的账户转出

收款账户可以属于其他用户，但付款账户必须属于当前登录用户：

```go
fromAccount, valid := server.validAccount(
    ctx,
    req.FromAccountID,
    req.Currency,
)
if !valid {
    return
}

authPayload := ctx.MustGet(authorizationPayloadKey).(*token.Payload)
if fromAccount.Owner != authPayload.Username {
    err := errors.New(
        "from account doesn't belong to the authenticated user",
    )
    ctx.JSON(http.StatusUnauthorized, errorResponse(err))
    return
}
```

为此，`validAccount` 从只返回 `bool` 改为返回 `(db.Account, bool)`。handler 在完成“账户存在、币种匹配”的检查后，可以继续使用查到的账户判断 owner，不需要重复查库。

## 给中间件和受保护接口补测试

### 中间件测试

`api/middleware_test.go` 先封装一个添加 Authorization header 的辅助函数：

```go
func addAuthorization(
    t *testing.T,
    request *http.Request,
    tokenMaker token.Maker,
    authorizationType string,
    username string,
    duration time.Duration,
) {
    token, err := tokenMaker.CreateToken(username, duration)
    require.NoError(t, err)

    authorizationHeader := fmt.Sprintf("%s %s", authorizationType, token)
    request.Header.Set(authorizationHeaderKey, authorizationHeader)
}
```

然后用表驱动测试覆盖：

| case | header 状态 | 期望 |
| ---- | ---- | ---- |
| `OK` | 合法 Bearer token | 200 |
| `NoAuthorization` | 没有 header | 401 |
| `UnsupportedAuthorization` | 类型不是 Bearer | 401 |
| `InvalidAuthorizationFormat` | 格式不完整 | 401 |
| `ExpiredToken` | token 已过期 | 401 |

测试专门注册一个只挂 `authMiddleware` 的 `/auth` 路由，因此失败时能明确定位到中间件，而不是某个业务 handler。

### API 测试统一携带 token

账户和转账路由变成受保护路由后，原有成功测试也必须携带合法 token：

```go
setupAuth: func(
    t *testing.T,
    request *http.Request,
    tokenMaker token.Maker,
) {
    addAuthorization(
        t,
        request,
        tokenMaker,
        authorizationTypeBearer,
        account.Owner,
        time.Minute,
    )
},
```

同时新增两类关键分支：

- **`NoAuthorization`**：没有 token 时，中间件直接返回 401，store 不应被调用；
- **`UnauthorizedUser`**：token 合法，但 payload 里的用户不是账户 owner，handler 返回 401，写操作不应执行。

这些 `Times(0)` 断言很重要。它们不仅检查状态码，还确认鉴权失败后没有继续访问数据库或执行转账：

```go
store.EXPECT().
    TransferTx(gomock.Any(), gomock.Any()).
    Times(0)
```

### 补全转账接口测试

转账 API 还补充了完整的表驱动测试，覆盖：

- 正常转账；
- 转出或转入账户不存在；
- 转出或转入账户币种不匹配；
- 非法币种、负数金额；
- 查询账户失败、事务失败；
- 登录用户不是转出账户 owner；
- 没有 Authorization header。

这组测试把“输入校验 → 账户校验 → owner 授权 → 执行事务”的调用顺序也固定下来。前一步失败时，后面的 store 方法必须是 `Times(0)`。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `token.Payload` | 统一保存 token ID、用户名、签发时间和过期时间 |
| `token.Maker` | 隔离 API 层与 JWT / PASETO 的具体实现 |
| `JWTMaker` | 用 HS256 签名验签，并限制算法、强制过期时间 |
| `PasetoMaker` | 用 PASETO `v4.local` 加密、认证和验证 payload |
| `POST /users/login` | 用户名和密码正确后签发短期 access token |
| `authMiddleware` | 统一解析 Bearer token，把已认证 payload 放进 Gin context |
| 受保护 route group | 注册和登录保持公开，账户和转账接口必须先认证 |
| handler 授权规则 | owner 只能来自 token，禁止访问或转出他人的账户 |
| SQL `WHERE owner = $1` | 在数据库查询阶段限制账户列表的数据范围 |
| token / middleware / API 测试 | 覆盖过期、错误算法、缺少 token、越权和转账异常分支 |

到这里，API 已经不再只相信客户端提交的参数：用户身份来自经过密码学验证的 token，资源归属则由服务端和数据库共同检查。

下一节 [13. 构建 Docker 镜像](./13_build_docker_image.md) 会把应用及其运行环境打包成镜像，为后续部署做准备。
