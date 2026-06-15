# 11. 密码存储

[10. 处理数据库错误](./10_handle_db_errors.md) 把 `users` 表建好了，但 `hashed_password` 那一列在测试里还塞着 `"secret"` 这种明文字面量。这一节把这件事补完：

1. **不能存明文**：用 bcrypt 把密码哈希后再写库；
2. **暴露 `POST /users` 接口**：让客户端能自己注册账号；
3. **handler 层的 mock 测试**：添加 mock 测试，把 `createUser` 的 6 条分支都覆盖上；
4. **自定义 gomock matcher**：handler 内部会临时生成一次哈希，导致测试根本不知道 `CreateUserParams.HashedPassword` 应该等于什么。这一节顺便讲怎么写一个能"反过来用 `CheckPassword` 验证"的 matcher，把这块灰区补上。

## 为什么是 bcrypt 而不是 SHA-256

哈希算法种类很多，但**用来存密码的哈希算法是另一个品类**。常见的 SHA-256 / SHA-512 / MD5 都属于"通用快速哈希"，设计目标是越快越好——这恰好是密码存储最不想要的特性：

- **快 = 暴力破解便宜**：现代 GPU 一秒能算上百亿次 SHA-256，一张普通显卡几小时就能把 8 位常见密码字典撞穿；
- **没有 salt**：同一个密码哈希出来的值永远相同。如果两个用户的密码都是 `123456`，库里存的 hash 也完全一样——攻击者拿到泄露的密码表后，用一张预先算好的 rainbow table（"密码 → hash"的预计算映射）就能批量反查。

下面把 hash 一个密码这件事拆开来讲。

### Salt 是什么，为什么必须有

Salt 是一段**每次 hash 都重新生成的随机字节**。在 bcrypt 里它是 16 字节，由系统随机源（`crypto/rand`）产生。

- hash 的输入从"只有 password"变成"password + salt"；
- salt 每次都不一样 → 同一个密码每次 hash 出来都不一样；
- 结果 → rainbow table 失效。攻击者要为每一条泄露的 hash 单独算一遍候选密码；提前算好的字典也派不上用场，因为那是为某个固定 salt 算的，换一条记录就要重算。

但 salt 本身不是秘密。验证密码的时候要重新算一遍 hash 和库里的对比，必须用回当初那条 salt——所以 salt 一定要存下来。bcrypt 的处理方式是 salt 直接拼在 hash 字符串里。

### Hash 一个密码的步骤

bcrypt 接收三个输入：

- `password`：用户提供的明文，最长 72 字节；
- `salt`：16 字节随机数；
- `cost`：一个整数（默认 10），控制下面第 1 步要重复多少次。

输出是一段固定 60 字符的字符串。完整流程分四步：

**第 1 步：用 `password + salt + cost` 派生出一份"内部状态"**

bcrypt 内部有一张几 KB 的查找表（包括一个 18 项的子密钥数组和 4 张 256 项的 S-box，初值是 π 的小数部分填出来的常量）。这一步要做的，就是**用 password 和 salt 反复交替地改写这张表**，把它变成一个完全由 `password + salt` 决定的状态。

这个改写过程要重复 `2^cost` 次——cost 是 10 时就是 1024 次，每次都要把这张表整个走一遍。这是 bcrypt 唯一"慢"的地方，也是它故意为之的核心：

- 同样的 `password + salt`，每次跑出来的状态都是一样的；
- 但任何一比特的改动（换个 salt、换个密码、cost 不同）都会让最终的状态完全不同；
- 攻击者每尝试一个候选密码都得把这 1024 次完整跑一遍，没法走捷径。

**第 2 步：用这份状态把一段固定明文加密 64 次**

bcrypt 写死了一段 24 字节的明文：`"OrpheanBeholderScryDoubt"`。拿第 1 步派生出的状态当作密钥，把这 24 字节明文加密 64 次，最后剩下的 24 字节密文就是这次 hash 的"原始输出"。

**第 3 步：把 24 字节原始输出编码成可读字符串**

bcrypt 用了一种自定义的 base64 变体，把 24 字节编码成 31 个 ASCII 字符。salt 也用同样的方法，把 16 字节编码成 22 个字符。

**第 4 步：把所有验证需要的信息拼成一个字符串**

最终输出长这样：

```
$2a$10$umU5kyOaI90UEUXjNdciBuaFkiDsmFvC3fV1BKEQsG85yLBXVg4U2
 ^^ ^^ ^^^^^^^^^^^^^^^^^^^^^^ ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
 │   │           │                          │
版本 cost      salt（22 字符）          hash（31 字符）
```


| 段 | 内容 | 作用 |
| ---- | ---- | ---- |
| `2a` | 算法版本号 | 历史上 bcrypt 的实现修过几次 bug，版本号让验证逻辑知道按哪一版的规则重算 |
| `10` | cost | 验证时要按同样的 cost 重算第 1 步 |
| 22 字符 | 编码后的 salt | 验证时要拿出来当输入 |
| 31 字符 | 编码后的 hash | 用来和重算结果比对 |


验证密码这件事不需要任何额外信息。库表里只存 `hashed_password`，验证时把用户输入的明文 + 这串字符一起喂给 `CompareHashAndPassword`，bcrypt 自己把 cost 和 salt 从字符串里切出来，按同样的参数重新走一遍上面的 4 步，最后比对 hash 那一段相不相等。

### 一些会踩到的边界

- **password 最长 72 字节**：第 1 步把 password 当作"密钥"喂进去，超出 72 字节的部分被静默截断。这一节用 `min=6` 保下限，线上要稳的话可以在 handler 里再加一条 `max=72` 的校验。
- **同一个密码两次 hash 结果不同**：因为每次 salt 不同。验证时不是"重算 hash 看看一不一样"，而是"按字符串里的 salt + cost 重算一遍看 hash 段相不相等"。这是 bcrypt 设计的核心保证。

## 封装 `HashPassword` / `CheckPassword`

新建 `util/password.go`：

```go
package util

import (
    "fmt"

    "golang.org/x/crypto/bcrypt"
)

// HashPassword returns the bcrypt hash of the password
func HashPassword(password string) (string, error) {
    hashedPassword, err := bcrypt.GenerateFromPassword([]byte(password), bcrypt.DefaultCost)
    if err != nil {
        return "", fmt.Errorf("failed to hash password: %s", err)
    }
    return string(hashedPassword), nil
}

// CheckPassword checks if the provided password is correct or not
func CheckPassword(password, hashedPassword string) error {
    return bcrypt.CompareHashAndPassword([]byte(hashedPassword), []byte(password))
}
```

两个函数其实都只是 `bcrypt` 标准库的薄壳，但封一层有几个好处：

- **类型从 `[]byte` 收成 `string`**：`bcrypt` 用 `[]byte` 是历史习惯，业务层用 `string` 更顺；
- **错误信息加上"failed to hash password"前缀**：定位日志时知道这条错误是从哪条路径上来的；
- **算法选择留在一处**：哪天想把 cost 从 10 调到 12，或者整体迁移到 argon2，只用改这一个文件。

### 测试一下

`util/password_test.go`：

```go
func TestPassword(t *testing.T) {
    password := RandomString(6)

    hashedPassword, err := HashPassword(password)
    require.NoError(t, err)
    require.NotEmpty(t, hashedPassword)

    err = CheckPassword(password, hashedPassword)
    require.NoError(t, err)

    wrongPassword := RandomString(8)
    err = CheckPassword(wrongPassword, hashedPassword)
    require.EqualError(t, err, bcrypt.ErrMismatchedHashAndPassword.Error())

    hashedPassword2, err := HashPassword(password)
    require.NoError(t, err)
    require.NotEmpty(t, hashedPassword2)
    require.NotEqual(t, hashedPassword, hashedPassword2)
}
```


| 断言 | 验证的性质 |
| ---- | ---- |
| `CheckPassword(password, hashedPassword) == nil` | 同一对密码能验通 |
| `CheckPassword(wrongPassword, ...) == ErrMismatchedHashAndPassword` | 错的密码会被库明确拒掉 |
| `hashedPassword != hashedPassword2` | 两次哈希同一个密码结果不同 |


## 把 `user_test.go` 里的 `"secret"` 替掉

[10](./10_handle_db_errors.md) 里 `db/sqlc/user_test.go` 用的是字面量 `HashedPassword: "secret"`，这里换成真哈希更接近线上行为：

```go
func createRandomUser(t *testing.T) User {
    hashedPassword, err := util.HashPassword(util.RandomString(6))
    require.NoError(t, err)
    arg := CreateUserParams{
        Username:       util.RandomOwner(),
        HashedPassword: hashedPassword,
        FullName:       util.RandomOwner(),
        Email:          util.RandomEmail(),
    }
    // ...
}
```

## `POST /users` handler

新建 `api/user.go`：

```go
type createUserRequest struct {
    Username string `json:"username" binding:"required,alphanum"`
    Password string `json:"password" binding:"required,min=6"`
    FullName string `json:"full_name" binding:"required"`
    Email    string `json:"email" binding:"required,email"`
}

type createUserResponse struct {
    Username          string    `json:"username"`
    FullName          string    `json:"full_name"`
    Email             string    `json:"email"`
    PasswordChangedAt time.Time `json:"password_changed_at"`
    CreatedAt         time.Time `json:"created_at"`
}

func (server *Server) createUser(ctx *gin.Context) {
    var req createUserRequest
    if err := ctx.ShouldBindJSON(&req); err != nil {
        ctx.JSON(http.StatusBadRequest, errorResponse(err))
        return
    }

    hashedPassword, err := util.HashPassword(req.Password)
    if err != nil {
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
    }

    arg := db.CreateUserParams{
        Username:       req.Username,
        HashedPassword: hashedPassword,
        FullName:       req.FullName,
        Email:          req.Email,
    }

    user, err := server.store.CreateUser(ctx, arg)
    if err != nil {
        if pqErr, ok := err.(*pq.Error); ok {
            switch pqErr.Code.Name() {
            case "unique_violation":
                ctx.JSON(http.StatusForbidden, errorResponse(err))
                return
            }
        }
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return
    }

    rsp := createUserResponse{
        Username:          user.Username,
        FullName:          user.FullName,
        Email:             user.Email,
        PasswordChangedAt: user.PasswordChangedAt,
        CreatedAt:         user.CreatedAt,
    }
    ctx.JSON(http.StatusOK, rsp)
}
```

几个要点：

- **`Username` 用 `alphanum`，不用 `email` 那套规则**：库里 `username` 是主键，业务上想保留"短而干净"的字符集；用 `alphanum` 把空格、连字符、`#` 这些直接挡在 tag 校验阶段；
- **`Password` 用 `min=6`**：6 是 bcrypt 能接受的下限附近的"业务允许最低复杂度"；线上要更严的话再加自定义 validator；
- **`createUserResponse` 不包含 `HashedPassword`**：哈希过的密码也是密码，**不能让它出 API 边界**。直接用 `db.User` 当响应体的话，`json:"hashed_password"` 那一列会被序列化进去——这是后面测试 `requireBodyMatchUser` 里 `require.Empty(t, gotUser.HashedPassword)` 这条断言要守住的不变量；
- **`unique_violation` → 403**：和 [10](./10_handle_db_errors.md) 里 `createAccount` 处理同类错误的策略保持一致——username / email 任一字段冲突时，告诉客户端"这是你那边的问题"，而不是 500。

最后在 `NewServer` 里加路由：

```go
router.POST("/users", server.createUser)
```

## 给 `/users` 写 mock 测试

给 `createUser` 写一组覆盖 6 条分支的测试。

`api/user_test.go`：

```go
func TestCreateUserAPI(t *testing.T) {
    user, password := randomUser(t)

    testCases := []struct {
        name          string
        body          gin.H
        buildStubs    func(store *mockdb.MockStore)
        checkResponse func(recoder *httptest.ResponseRecorder)
    }{
        {
            name: "OK",
            body: gin.H{
                "username":  user.Username,
                "password":  password,
                "full_name": user.FullName,
                "email":     user.Email,
            },
            buildStubs: func(store *mockdb.MockStore) {
                store.EXPECT().
                    CreateUser(gomock.Any(), gomock.Any()).
                    Times(1).
                    Return(user, nil)
            },
            checkResponse: func(recorder *httptest.ResponseRecorder) {
                require.Equal(t, http.StatusOK, recorder.Code)
                requireBodyMatchUser(t, recorder.Body, user)
            },
        },
        // InternalError / DuplicateUsername / InvalidUsername /
        // InvalidEmail / TooShortPassword 五个 case ……
    }

    for i := range testCases {
        tc := testCases[i]
        t.Run(tc.name, func(t *testing.T) {
            ctrl := gomock.NewController(t)
            defer ctrl.Finish()

            store := mockdb.NewMockStore(ctrl)
            tc.buildStubs(store)

            server := NewServer(store)
            recorder := httptest.NewRecorder()

            data, err := json.Marshal(tc.body)
            require.NoError(t, err)

            url := "/users"
            request, err := http.NewRequest(http.MethodPost, url, bytes.NewReader(data))
            require.NoError(t, err)

            server.router.ServeHTTP(recorder, request)
            tc.checkResponse(recorder)
        })
    }
}
```

添加辅助函数：

```go
func randomUser(t *testing.T) (user db.User, password string) {
    password = util.RandomString(6)
    hashedPassword, err := util.HashPassword(password)
    require.NoError(t, err)

    user = db.User{
        Username:       util.RandomOwner(),
        HashedPassword: hashedPassword,
        FullName:       util.RandomOwner(),
        Email:          util.RandomEmail(),
    }
    return
}

func requireBodyMatchUser(t *testing.T, body *bytes.Buffer, user db.User) {
    data, err := io.ReadAll(body)
    require.NoError(t, err)

    var gotUser db.User
    err = json.Unmarshal(data, &gotUser)

    require.NoError(t, err)
    require.Equal(t, user.Username, gotUser.Username)
    require.Equal(t, user.FullName, gotUser.FullName)
    require.Equal(t, user.Email, gotUser.Email)
    require.Empty(t, gotUser.HashedPassword)
}
```

- **`randomUser` 同时返回明文 `password` 和哈希后的 `user`**：明文要喂给 request body，哈希要塞进 mock 的 `Return(user, nil)`；
- **`requireBodyMatchUser` 把响应反序列化成 `db.User`**：`db.User` 上有 `json:"hashed_password"` tag，所以**如果 handler 不小心把 `db.User` 直接当成响应体丢出去，`gotUser.HashedPassword` 就不会是空**。

## 自定义 gomock matcher

到目前为止，`OK` 这条 case 用的是 `CreateUser(gomock.Any(), gomock.Any())`——两个参数都不校验。但这有点弱：handler 完全可能把 `req.Username` 错塞成 `req.FullName`，或者把 `req.Email` 漏掉，测试照样通过。

正常情况下，期望值长什么样、就用 `gomock.Eq(arg)` 把那个 `arg` 整个比一遍：

```go
arg := db.CreateUserParams{
    Username:       user.Username,
    HashedPassword: ???,            // ← 卡在这里
    FullName:       user.FullName,
    Email:          user.Email,
}
store.EXPECT().
    CreateUser(gomock.Any(), gomock.Eq(arg)).
    Times(1).
    Return(user, nil)
```

但这里有一个绕不过去的问题：**测试根本没法预先知道 `HashedPassword` 的值**。

回头看 handler：

```go
hashedPassword, err := util.HashPassword(req.Password)
// ...
arg := db.CreateUserParams{
    HashedPassword: hashedPassword,  // ← 这一行的值是 handler 内部当场算出来的
    ...
}
```

`HashPassword` 内部 `bcrypt.GenerateFromPassword` 用了一个随机 salt，**每次调用结果都不一样**——也就是说测试侧无论怎么准备 `arg`，被测函数跑出来的 `HashedPassword` 却每次都是不一样的。

我们真正想要的是"逐字段 deep equal，但 `HashedPassword` 这一列改成走密码验证"——只要明文密码能和实际算出来的 hash 对得上（`CheckPassword` 不报错）就算通过，其余字段照常比对。

`gomock` 内置的 matcher（`Eq` / `Any` / `Nil` / `Not` 等）没有"按字段定制比较规则"这种能力。这种"逐字段 deep equal，但 `HashedPassword` 这一列改成走密码验证"的混合规则，gomock 给的扩展点就是**自己实现一个 `Matcher` 接口**。

### gomock 的 `Matcher` 接口

`gomock.Matcher` 一共两个方法：

```go
type Matcher interface {
    Matches(x any) bool
    String() string
}
```

- `Matches(x any) bool` —— gomock 在 mock 方法被实际调用时，会拿真实参数 `x` 调这个函数，返回 `true` 表示"这个参数符合期望"。
- `String() string` —— 不匹配时 gomock 拿这行打印 "got vs expected" 的 expected 那一侧。

`store.EXPECT().CreateUser(gomock.Any(), gomock.Any())` 这一行里，**两个 `gomock.Any()` 传进去的是对象，不是函数**——它们是实现了 `Matcher` 接口的类型。被测代码后续真的调到 `MockStore.CreateUser(ctx, arg)` 时，gomock controller 内部大致这么循环（伪代码）：

```go
for _, call := range expectedCalls["CreateUser"] {
    if call.matchers[0].Matches(realCtx) && call.matchers[1].Matches(realArg) {
        return call.handle(realCtx, realArg)  // Times / Return 都在这里生效
    }
}
t.Fatalf("unexpected call to CreateUser(%v, %v)", realCtx, realArg)
```

也就是说，`EXPECT().CreateUser(...)` 里写的每一个参数都是一条**匹配规则**，gomock 在被调用时挨个问"这条规则吃不吃这个真实参数"，全部 `Matches` 返回 `true` 才算这条期望命中。

#### `gomock.Eq` / `gomock.Any` 是什么

`Eq` 和 `Any` 不是 gomock 在外面套了一层魔法——它们就是**两个普普通通的 `Matcher` 实现**，源码加起来不到二十行：

```go
// gomock 内部（精简）
type anyMatcher struct{}
func (anyMatcher) Matches(any) bool { return true }
func (anyMatcher) String() string   { return "is anything" }

func Any() Matcher { return anyMatcher{} }

type eqMatcher struct{ x any }
func (e eqMatcher) Matches(x any) bool { return reflect.DeepEqual(e.x, x) }
func (e eqMatcher) String() string     { return fmt.Sprintf("is equal to %v", e.x) }

func Eq(x any) Matcher { return eqMatcher{x} }
```

`Eq` 之所以"严格比较"是因为它的 `Matches` 就一行 `reflect.DeepEqual`；`Any` 之所以"什么都过"是因为它的 `Matches` 直接 `return true`。

> gomock 还做了一个便利：传给 `EXPECT().Method(...)` 的参数如果不是 `Matcher`，会被自动包成 `gomock.Eq(...)`。所以 `Eq(arg)` 和直接传 `arg` 等价。

#### 自定义 matcher = 自定义"匹配规则"

理解了上面这一层，回到我们的处境：现成的 `Eq` 用的是 `reflect.DeepEqual`，对 `HashedPassword` 是字面量比较；现成的 `Any` 又什么都不比。两条都不满足"按字段差异化对待"这种规则。

但 gomock 给的扩展点很干净——**只要能写出一个类型，让它实现 `Matches(x any) bool` 和 `String() string` 这两个方法，它就能当 matcher 用**。`Matches` 里能写任意 Go 代码：调 `CheckPassword`、忽略某些字段、按数值范围匹配、按 JSON 字段匹配，全都行。

具体到 `CreateUserParams`，我们想要的规则用伪代码描述就是：

```
Matches(x):
    if x 不是 CreateUserParams: return false
    if CheckPassword(预期密码, x.HashedPassword) 失败: return false
    比较其他字段（Username / FullName / Email），全部相等才返回 true
```

下面这段实现就是这条规则的字面翻译。

```go
type eqCreateUserParamsMatcher struct {
    arg      db.CreateUserParams
    password string
}

func (e eqCreateUserParamsMatcher) Matches(x any) bool {
    arg, ok := x.(db.CreateUserParams)
    if !ok {
        return false
    }

    err := util.CheckPassword(e.password, arg.HashedPassword)
    if err != nil {
        return false
    }

    e.arg.HashedPassword = arg.HashedPassword
    return reflect.DeepEqual(e.arg, arg)
}

func (e eqCreateUserParamsMatcher) String() string {
    return fmt.Sprintf("matches arg %v and password %v", e.arg, e.password)
}

func EqCreateUserParams(arg db.CreateUserParams, password string) gomock.Matcher {
    return eqCreateUserParamsMatcher{arg, password}
}
```

**只暴露工厂函数 `EqCreateUserParams`**：`eqCreateUserParamsMatcher` 类型本身不导出，对外只暴露"用法"。

### 接到 `OK` 这条 case 上

```go
buildStubs: func(store *mockdb.MockStore) {
    arg := db.CreateUserParams{
        Username: user.Username,
        FullName: user.FullName,
        Email:    user.Email,
    }
    store.EXPECT().
        CreateUser(gomock.Any(), EqCreateUserParams(arg, password)).
        Times(1).
        Return(user, nil)
},
```

注意期望 `arg` 里**没有写 `HashedPassword`**——它的零值会被 matcher 里那行赋值覆写掉。把这块字段从期望里抽掉，比起每次构造一个假 hash 再硬塞进去更直白。

这一行下去之后，`OK` case 就能验证更多事：handler 必须把请求里 `username` / `full_name` / `email` 三个字段**原样**传给 `CreateUser`，并且必须把 `password` 哈希后再放到第四个字段。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `util/password.go` 加 `HashPassword` / `CheckPassword` | 把 bcrypt 这个"密码专用慢哈希"封装到一处，业务层不直接依赖 `golang.org/x/crypto/bcrypt` |
| `util/password_test.go` | 钉死 bcrypt 的几个性质：salt 随机、wrong-password 报特定错误 |
| `db/sqlc/user_test.go` 把 `"secret"` 换成真哈希 | 让 CRUD 测试也走过一次完整的 `HashPassword`，顺带验证字段长度够 |
| `api/user.go` 加 `POST /users` handler | 暴露注册接口；`createUserResponse` 不含哈希，避免密码相关字段穿过 API 边界 |
| `api/user_test.go` 6 条 case + `requireBodyMatchUser` | 覆盖 4 条校验失败 + 1 条 store 报错 + 1 条成功路径；用 `db.User` 反序列化盯响应里有没有泄露 `hashed_password` |
| `requireBodyMatchError` | 非 200 case 也校验响应体的形状，防止 `errorResponse` 结构悄悄被改 |
| `EqCreateUserParams` 自定义 matcher | 解决"handler 内部哈希后测试不知道实际值"的问题，仍能精确断言其他字段 |

bcrypt 把"明文密码进库"这件事彻底关掉之后，下一步就该考虑：**用户登录之后，怎么让后续的 `/accounts`、`/transfers` 知道"是谁在请求"？**

下一节 [12. Token 认证](./12_token_authentication.md) 会加一个 `POST /users/login`，签发 PASETO / JWT token，并把"必须是账户的 owner 才能查这个账户"的鉴权规则补上。
