# 09. 自定义参数校验器

到上一节为止，"货币是否合法"这件事的写法是：

```go
type createAccountRequest struct {
    Owner    string `json:"owner" binding:"required"`
    Currency string `json:"currency" binding:"required,oneof=USD EUR"`
}
```

`oneof=USD EUR` 把允许的货币硬编码在 struct tag 里。本节要做两件事：

1. 把货币列表从 tag 里搬出去，沉淀到 `util` 包，统一由 `IsSupportedCurrency` 决定哪些是合法币种；
2. 加一个 `POST /transfers` 转账接口 —— 它不光要校验 `currency` 合法，还要保证两个账户的币种与请求一致。

这两件事顺势引出一个共同的需求：**`binding` 标签里不要再硬编码 `oneof=USD EUR` 这种字面量**，而是用一个有名字的 tag（比如 `currency`）来代表"合法币种"这条规则，规则的真实定义放在代码里维护。

## 为什么 `oneof` 不够用

`oneof` 是 [`go-playground/validator`](https://github.com/go-playground/validator) 内置的一条规则，胜在零依赖、写法直观，但它有几个硬伤：

1. **可选项写死在 tag 里**：每个用到 currency 的请求结构都要重抄一遍 `oneof=USD EUR`。新增 `CAD` 时要扫一遍所有引用，漏改一处就是 bug；
2. **tag 表达力有限**：`oneof` 只能列举字面量。哪天规则变成"对某些用户开放试点币种"或者"币种合法性要查表"，tag 就再也写不下了，还是得回去写一个真正的函数；

把这三件事一次性收掉的做法是：把"什么是合法货币"的定义集中到一处用代码维护，再把这段代码注册成 validator 的一条自定义规则，让 tag 里只剩规则的名字。

## 把币种集中到 `util/currency.go`

```go
// util/currency.go
package util

const (
    USD = "USD"
    EUR = "EUR"
    CAD = "CAD"
)

func IsSupportedCurrency(currency string) bool {
    switch currency {
    case USD, EUR, CAD:
        return true
    }
    return false
}
```

顺手把 `util/random.go` 里的 `RandomCurrency` 也改成引用这几个常量，避免再用裸字符串：

```go
// util/random.go
func RandomCurrency() string {
    currencies := []string{EUR, USD, CAD}
    n := len(currencies)
    return currencies[rand.Intn(n)]
}
```

这样"项目支持哪些币种"只剩下一个事实来源 —— `util/currency.go`。新增一种货币只要改 `const` 和 `switch`，调用方什么都不用动。

## 注册自定义 validator

要把 `binding:"...,currency"` 跑通，得先理解一条请求从 gin 进来后，参数校验到底是谁在做。

### 调用链：gin → validator → tag

`go-playground/validator/v10` 的核心类型是 `*validator.Validate`，它内部维护一张 `map[string]Func` —— **tag 名 → 校验函数**。包初始化时，`required` / `oneof` / `min` / `gt` 这些内置 tag 已经自带，调用 `Validate.RegisterValidation(name, fn)` 就是往这张表里再插一条。

gin 把这个引擎包了一层。`gin/binding` 包里有一个全局变量：

```go
// gin/binding/binding.go（精简）
var Validator StructValidator = &defaultValidator{}

type StructValidator interface {
    ValidateStruct(any) error
    Engine() any
}

type defaultValidator struct {
    once     sync.Once
    validate *validator.Validate
}

func (v *defaultValidator) Engine() any {
    v.lazyinit()
    return v.validate
}
```

- `binding.Validator` 是个 `StructValidator` 接口，所有 `ShouldBindJSON` / `ShouldBindUri` / `ShouldBindQuery` 在解码完字段之后都会调它的 `ValidateStruct(req)`；
- gin 自己不实现校验逻辑，`defaultValidator.validate` 才是真正干活的 `*validator.Validate`；
- `Engine()` 返回 `any`，目的是不在公共接口上暴露具体的校验库 —— 万一 gin 哪天换底层，接口还能保持稳定。

整条调用链摊开来是这样：

```
ctx.ShouldBindJSON(&req)
    └─> json.Unmarshal(body, &req)               // 反序列化
    └─> binding.Validator.ValidateStruct(&req)   // 走全局 StructValidator
            └─> defaultValidator.validate.Struct(&req)
                    └─> 反射遍历每个字段
                            └─> 解析 `binding:"required,currency"`，按逗号拆成 ["required", "currency"]
                                    └─> 从 map 里查 "currency" → 拿到 validCurrency
                                            └─> 构造 FieldLevel，调 validCurrency(fl)
                                                    └─> 返回 false → 整个 ValidateStruct 报错 → handler 收到 400
```

注册自定义 validator 这件事就是 **在这张 map 里多插一行**。

### 写校验函数

新建 `api/validator.go`：

```go
package api

import (
    "github.com/MorePeanuts/simplebank/util"
    "github.com/go-playground/validator/v10"
)

var validCurrency validator.Func = func(fl validator.FieldLevel) bool {
    if currency, ok := fl.Field().Interface().(string); ok {
        // check currency is supported
        return util.IsSupportedCurrency(currency)
    }
    return false
}
```

`validator.Func` 的签名是库定的：

```go
type Func func(fl FieldLevel) bool
```

只有一个入参 `FieldLevel`，没有别的途径能拿到字段值 —— 这正是 validator 的设计：**校验函数对外只暴露"当前字段"的视图，不让你穿过去访问别的字段或上下文**，避免规则之间互相耦合。`FieldLevel` 这个接口提供的常用方法包括：

| 方法 | 作用 |
| ---- | ---- |
| `Field()` | 当前字段的 `reflect.Value`，可以拿值、判类型 |
| `FieldName()` | 字段名（错误信息里 `Field validation for 'Currency' failed on the 'currency' tag` 中的 `Currency` 就是这里来的） |
| `Param()` | tag 后面跟的参数。比如 `oneof=USD EUR` 的 `USD EUR` 就是从这里取的；本节的 `currency` tag 不带参数，所以用不到 |
| `Parent()` | 当前字段所属的 struct，用来做"两个字段的关系"校验 |

`validCurrency` 只用了 `fl.Field()`。两个细节：

- **必须做类型断言**：`currency` 这个 tag 本身没法约束"只能贴在 `string` 字段上"，使用类型断言可以避免不小心把 `currency` 写到了一个 `int` 字段上。
- 校验逻辑只剩一行 `util.IsSupportedCurrency(currency)`：所有"什么是合法货币"的细节都在 `util` 包里 —— 校验函数和"合法币种"的真实定义解耦。

### 把它挂到 gin 的引擎上

改 `api/server.go` 里的 `NewServer`：

```go
import (
    // ...
    "github.com/gin-gonic/gin/binding"
    "github.com/go-playground/validator/v10"
)

func NewServer(store db.Store) *Server {
    server := &Server{store: store}
    router := gin.Default()

    if v, ok := binding.Validator.Engine().(*validator.Validate); ok {
        err := v.RegisterValidation("currency", validCurrency)
        if err != nil {
            log.Fatal("currency validator registration error")
        }
    }

    // ...
}
```

逐步对照前面那张调用链看：

1. **`binding.Validator.Engine()`** 返回 `any`，里面藏的就是 `defaultValidator.validate` —— 那个 `*validator.Validate`。
2. **`(*validator.Validate)` 类型断言** 才能调到 `RegisterValidation`。如果未来 gin 换底层校验库，这条断言会失败，注册过程会被跳过。
3. **`v.RegisterValidation("currency", validCurrency)`** 往那张 `map[string]Func` 里插一条 `"currency" → validCurrency`。
4. **注册时机**：必须在第一次接到请求之前完成。`NewServer` 这个位置正好满足 —— 任何请求都得先经过 `Server`，到达 handler 时 map 已经写好。
5. **注册失败直接 `log.Fatal`**：库参数是写死的，正常情况下不会失败。如果真的失败（比如重名占用），程序应该当场停下，不要带着"看起来在跑、其实校验器没生效"的状态接客。

注册完成之后，`currency` 的工作机制和 `required` 完全一样 —— gin 在 `ShouldBindJSON` 里调 `ValidateStruct` 时会自动走到这条规则。从 handler 角度看不到任何差别：

```go
type createAccountRequest struct {
    Owner    string `json:"owner" binding:"required"`
    Currency string `json:"currency" binding:"required,currency"`
}
```

`binding:"required,currency"` 里的两条规则按顺序执行：先确认字段非空（`required`），再调 `validCurrency` 看值在不在合法集合里。任意一条失败，`ShouldBindJSON` 就返回错误，handler 直接走 400 分支。

## 加上 `POST /transfers` 接口

```go
type transferRequest struct {
    FromAccountID int64  `json:"from_account_id" binding:"required,min=1"`
    ToAccountID   int64  `json:"to_account_id" binding:"required,min=1"`
    Amount        int64  `json:"amount" binding:"required,gt=0"`
    Currency      string `json:"currency" binding:"required,currency"`
}

func (server *Server) createTransfer(ctx *gin.Context) {
    var req transferRequest
    if err := ctx.ShouldBindJSON(&req); err != nil {
        ctx.JSON(http.StatusBadRequest, errorResponse(err))
        return
    }

    if !server.validAccount(ctx, req.FromAccountID, req.Currency) {
        return
    }

    if !server.validAccount(ctx, req.ToAccountID, req.Currency) {
        return
    }

    arg := db.TransferTxParams{
        FromAccountID: req.FromAccountID,
        ToAccountID:   req.ToAccountID,
        Amount:        req.Amount,
    }

    result, err := server.store.TransferTx(ctx, arg)
    if err != nil {
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return
    }

    ctx.JSON(http.StatusOK, result)
}
```

仅靠 `currency` tag 还不够。tag 只能保证"传入的 currency 字符串是合法币种"，没法保证"`from_account` 和 `to_account` 这两个账户在数据库里的 currency 真的等于 `req.Currency`"。后者依赖账户本身的状态，要 handler 自己去查。

`api/transfer.go` 末尾的 `validAccount` 就是干这件事的：

```go
func (server *Server) validAccount(ctx *gin.Context, accountID int64, currency string) bool {
    account, err := server.store.GetAccount(ctx, accountID)
    if err != nil {
        if err == sql.ErrNoRows {
            ctx.JSON(http.StatusNotFound, errorResponse(err))
            return false
        }

        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return false
    }

    if account.Currency != currency {
        err := fmt.Errorf("account [%d] currency mismatch: %s vs %s", account.ID, account.Currency, currency)
        ctx.JSON(http.StatusBadRequest, errorResponse(err))
        return false
    }

    return true
}
```

- **三种错误对应三种状态码**：账户不存在 → 404；查询本身报错 → 500；账户存在但币种不匹配 → 400（属于客户端传错参数）。把这三件事区分开，前端拿到响应能立刻分辨"是路由 / 鉴权问题还是参数本身有问题"。

主流程里两次调用 `validAccount`，先验 `from`，再验 `to`，一旦任何一边不通过就立刻 return。

最后在 `NewServer` 里加一行：

```go
router.POST("/transfers", server.createTransfer)
```

顺手把上一节遗留的拼写问题改掉 —— `router.GET("accounts", ...)` 漏了开头的斜杠：

```go
router.GET("/accounts", server.listAccounts)
```

> gin 内部对路径会做规范化处理，少一个斜杠目前不会真的报错。

## 验证一下

测试 `Create Transfer` 请求：

- Method: `POST`
- URL: `{{baseUrl}}/transfers`
- Body（JSON）：

```json
{
  "from_account_id": 1,
  "to_account_id": 2,
  "amount": 10,
  "currency": "USD"
}
```

为了同时观察四个分支，再在 collection 里把这个请求 **Duplicate** 三份，分别命名为 `Create Transfer - InvalidCurrency` / `... - CurrencyMismatch` / `... - AccountNotFound`，把 Body 改成对应的 payload。这样每个分支都有一份能直接 `Send` 复跑的请求，比每次手动改一个字段稳得多。

预期结果：

| 请求 | Body 关键字段 | 状态码 | 响应体要点 |
| ---- | ---- | ---- | ---- |
| `Create Transfer - InvalidCurrency` | `currency: "RMB"` | `400` | `Field validation for 'Currency' failed on the 'currency' tag` |
| `Create Transfer - CurrencyMismatch` | `currency: "EUR"`（账户实际是 USD） | `400` | `account [2] currency mismatch: USD vs EUR` |
| `Create Transfer - AccountNotFound` | `to_account_id: 99999` | `404` | `sql: no rows in result set` |
| `Create Transfer` | 全部对 | `200` | `TransferTxResult` 完整结构 |

四条对应四条不同的代码路径：第一条走的是 tag 校验，连 handler 都没进；第二条进了 handler 但被 `validAccount` 拦下；第三条触发 `sql.ErrNoRows` 分支；第四条全部通过，落到 `store.TransferTx`。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `util/currency.go` 新增 `IsSupportedCurrency` 和 `USD/EUR/CAD` 常量 | 把"项目支持哪些币种"集中到一个地方，避免多处字面量漂移 |
| `api/validator.go` 新增 `validCurrency`，`NewServer` 里 `RegisterValidation("currency", ...)` | 让 `binding:"...,currency"` 能直接当 tag 用，tag 里不再硬编码合法币种的字面量 |
| `createAccountRequest.Currency` 由 `oneof=USD EUR` 改成 `currency` | 用上自定义 validator，新增币种不再需要扫 handler |
| 新增 `api/transfer.go`、`POST /transfers` 路由 | 暴露转账接口；同步演示自定义 validator 的复用 |
| `validAccount` helper | 把"账户存在性 + 币种一致性"这种 tag 表达不了的二次校验封成可复用的小函数 |
| `router.GET("accounts", ...)` → `router.GET("/accounts", ...)` | 顺手修掉路径拼写 |

这一版仍然有几处问题：

- `createAccount` 在外键 / 唯一键冲突时还是返回 500，前端没办法分辨"这是参数问题还是数据库挂了" → [10. 处理数据库错误](./10_handle_db_errors.md)；
- `transferRequest` 没做"`FromAccountID == ToAccountID` 时直接拒绝"这种自校验，目前要等到 `TransferTx` 死锁回滚才暴露 —— 后续可以加成又一个自定义 validator。

下一节把数据库错误这块补完，让 handler 在 unique / foreign key 违例时返回更准确的状态码。
