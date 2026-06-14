# 06. RESTful HTTP API

这一节的目标是在 `Store` 之上加一层 HTTP 服务，把"创建账户、查询账户、列出账户"这三个最基础的能力通过 RESTful 接口暴露出去。

整体架构的分层是：

```
HTTP request → Gin Router → Handler → Store (sqlc + 事务) → PostgreSQL
```

新增一个 `api` 包专门承担 handler 这一层，业务逻辑仍然落在 `db.Store` 上，handler 只做"参数校验 → 调 store → 编码响应"这三件事。

Go 标准库的 `net/http` 已经能起 HTTP 服务了，但写 RESTful API 时会反复重写一些样板：路径参数解析、JSON 反序列化、参数校验、错误响应封装等。社区有几套常见的 Web 框架（[Gin](https://gin-gonic.com/)、[Echo](https://echo.labstack.com/)、[Fiber](https://gofiber.io/) 等），它们之间的差异并不大，本项目选 [Gin](https://github.com/gin-gonic/gin) 

```bash
go get github.com/gin-gonic/gin
```

## 定义 `Server` 结构

`api/server.go`：

```go
package api

import (
	db "github.com/MorePeanuts/simplebank/db/sqlc"
	"github.com/gin-gonic/gin"
)

// Server serves HTTP requests for our banking service.
type Server struct {
	store  *db.Store
	router *gin.Engine
}

// NewServer creates a new HTTP server and setup routing.
func NewServer(store *db.Store) *Server {
	server := &Server{store: store}
	router := gin.Default()

	router.POST("/accounts", server.createAccount)
	router.GET("/accounts/:id", server.getAccount)
	router.GET("accounts", server.listAccounts)

	server.router = router
	return server
}

// Start runs the HTTP servedr on a specific address.
func (server *Server) Start(address string) error {
	return server.router.Run(address)
}

func errorResponse(err error) gin.H {
	return gin.H{"error": err.Error()}
}
```

几个设计点：

- `Server` 同时持有 `*db.Store` 和 `*gin.Engine`：前者是业务数据层入口，后者是 HTTP 框架的路由引擎。所有 handler 都挂在 `Server` 的方法上，这样 handler 内部能直接通过 `server.store` 访问数据库，不需要再额外做依赖注入。
- `gin.Default()` 返回的是一个已经预挂了 `Logger` 和 `Recovery` 两个中间件的引擎：前者把每条请求的方法、路径、状态码、耗时打到日志里，后者在 handler panic 时兜底返回 500，避免把整个进程拖崩。如果需要更纯净的引擎，可以用 `gin.New()`。
- `Start(address)` 是一层薄包装，让 `main.go` 不需要直接接触 `*gin.Engine`，对外只暴露 "起在哪个地址" 这一个动作。
- `errorResponse` 把"返回错误"的 JSON 形状统一成 `{"error": "..."}`，三个 handler 都共用，避免每处都去手写 `gin.H{"error": err.Error()}`。`gin.H` 就是 `map[string]any` 的别名。

## 创建账户 `POST /accounts`

`api/account.go`：

```go
type createAccountRequest struct {
	Owner    string `json:"owner" binding:"required"`
	Currency string `json:"currency" binding:"required,oneof=USD EUR"`
}

func (server *Server) createAccount(ctx *gin.Context) {
	var req createAccountRequest
	if err := ctx.ShouldBindJSON(&req); err != nil {
		ctx.JSON(http.StatusBadRequest, errorResponse(err))
		return
	}

	arg := db.CreateAccountParams{
		Owner:    req.Owner,
		Currency: req.Currency,
		Balance:  0,
	}

	account, err := server.store.CreateAccount(ctx, arg)
	if err != nil {
		ctx.JSON(http.StatusInternalServerError, errorResponse(err))
	}

	ctx.JSON(http.StatusOK, account)
}
```

要点：

- `createAccountRequest` 是请求体的 DTO，**不直接复用 `db.CreateAccountParams`**：API 只允许调用方传 `owner` 和 `currency`。如果直接复用 `db.CreateAccountParams`，调用方就能在创建账户时把余额设成任意值，这是显然不允许的。
- `binding:"required"` 是 [go-playground/validator](https://github.com/go-playground/validator) 的标签语法，Gin 内部用它来做参数校验：
  - `required` 字段必须出现且非零值；
  - `oneof=USD EUR` 限制 `currency` 只能是 `USD` / `EUR` 中的一个，传别的值（包括 `cny`、`usd` 这种大小写不一致）都会被拒。
- `ShouldBindJSON` 把 body 反序列化到 `req` 上并跑 binding 校验。失败时直接返回 400，把校验器给的错误信息原样吐回去（生产场景往往会再做一层翻译，这里先简单处理）。
- 调到 `server.store.CreateAccount` 失败时返回 500。这一版**没有**区分错误类型（外键、唯一键冲突应该是 4xx 而不是 5xx），后续会在 [10. 处理数据库错误](./10_handle_db_errors.md) 里专门处理。

## 获取单个账户 `GET /accounts/:id`

```go
type getAccountRequest struct {
	ID int64 `uri:"id" binding:"required,min=1"`
}

func (server *Server) getAccount(ctx *gin.Context) {
	var req getAccountRequest
	if err := ctx.ShouldBindUri(&req); err != nil {
		ctx.JSON(http.StatusBadRequest, errorResponse(err))
		return
	}

	account, err := server.store.GetAccount(ctx, req.ID)
	if err != nil {
		if err == sql.ErrNoRows {
			ctx.JSON(http.StatusNotFound, errorResponse(err))
			return
		}

		ctx.JSON(http.StatusInternalServerError, errorResponse(err))
		return
	}

	ctx.JSON(http.StatusOK, account)
}
```

要点：

- 路径参数 `:id` 通过 `uri:"id"` 绑定到结构体上，配合 `ShouldBindUri` 就能复用同一套 binding 规则。`min=1` 限制 ID 必须是正整数 —— `bigserial` 在 Postgres 里从 1 开始递增，0 / 负数都是无效输入，提前在 handler 层挡掉，能省一次数据库往返。
- `GetAccount` 在 ID 不存在时返回的错误是 `sql.ErrNoRows`，这是 `database/sql` 在 `QueryRow().Scan()` 没匹配到行时的标准错误（参见 [03. CRUD 单元测试](./03_unit_test_for_crud.md#为-accounts-表编写单元测试)）。`sql.ErrNoRows` 映射成 404，而不是 500：这是"资源不存在"这个业务事实，不是服务端故障。其他错误（连接断了、SQL 异常等）才走 500。
- 这里用了 `err == sql.ErrNoRows` 直接比较 sentinel error，因为 sqlc 生成的代码里没有再去 `fmt.Errorf("%w", err)` 包一层。如果将来包装了，要改成 `errors.Is(err, sql.ErrNoRows)` 才稳。

## 分页列出账户 `GET /accounts`

```go
type listAccountsRequest struct {
	PageID   int32 `form:"page_id" binding:"required,min=1"`
	PageSize int32 `form:"page_size" binding:"required,min=5,max=10"`
}

func (server *Server) listAccounts(ctx *gin.Context) {
	var req listAccountsRequest
	if err := ctx.ShouldBindQuery(&req); err != nil {
		ctx.JSON(http.StatusBadRequest, errorResponse(err))
		return
	}

	arg := db.ListAccountsParams{
		Limit:  req.PageSize,
		Offset: (req.PageID - 1) * req.PageSize,
	}

	accounts, err := server.store.ListAccounts(ctx, arg)
	if err != nil {
		ctx.JSON(http.StatusInternalServerError, errorResponse(err))
		return
	}

	ctx.JSON(http.StatusOK, accounts)
}
```

要点：

- 列表接口对外的分页参数是"第几页 + 每页多少条"（`page_id` / `page_size`），更符合人类直觉；底层 SQL 用的是"偏移量 + 数量"（`offset` / `limit`）。在 handler 里完成 `offset = (page_id - 1) * page_size` 这次换算，业务接口和 SQL 接口各自维持自然的形态。
- `form:` 标签让参数从 query string 里取，配合 `ShouldBindQuery` 解析。比如 `GET /accounts?page_id=2&page_size=5`。
- `PageSize` 的范围 `min=5,max=10` 是一个有意识的设计：下限避免调用方退化成"逐条拉"（一页 1 条 ⇒ 几乎无分页价值），上限避免拉一次拽回成千上万行打爆服务端内存。生产里这个值应该结合实际数据规模再定。

## list 接口在没有数据时返回 `[]` 而不是 `nil`

直接把上面的 handler 跑起来，对一个没有任何账户的库发 `GET /accounts?page_id=1&page_size=5`，会发现响应体是：

```json
null
```

而不是预期的 `[]`。原因藏在 `sqlc` 生成的 `ListAccounts` 里：

```go
var items []Account
for rows.Next() {
    // ...
    items = append(items, i)
}
return items, nil
```

`var items []Account` 声明的是一个**值为 `nil` 的切片**，如果 `rows.Next()` 一次都没匹配上，`items` 就保持 `nil` 直接返回。`encoding/json` 在编码时对这两者的处理不同：`nil` slice 编成 `null`，长度为 0 的非 nil slice（如 `[]Account{}`）才编成 `[]`。

如果返回的是 `nil`，对前端来说，这是个非常容易踩的坑，原本可以无脑写 `data.forEach(...)` / `data.map(...)`，碰到 `null` 就要先做空值判断；TypeScript 类型如果声明成 `Account[]`，运行时拿到 `null` 还会触发解析错误。所以 **RESTful 接口的列表字段应该永远是 `[]`**，"无数据"不应该改变响应的结构。

修复方式有两条路：

1. handler 里手动兜底：拿到 `accounts` 后判空 `if accounts == nil { accounts = []db.Account{} }`，再写回响应。
2. 让 `sqlc` 直接生成空切片初始化的代码。

`sqlc` 在配置里提供了 [`emit_empty_slices`](https://docs.sqlc.dev/en/latest/reference/config.html#go) 开关，专门解决这个问题：

```yaml
# sqlc.yaml
sql:
  - engine: "postgresql"
    queries: "./db/query/"
    schema: "./db/migration/"
    gen:
      go:
        package: "db"
        out: "./db/sqlc"
        sql_package: "database/sql"
        sql_driver: "github.com/lib/pq"
        emit_json_tags: true
        emit_empty_slices: true   # 新增
```

打开后重新 `make sqlc`，所有 `:many` 查询生成的代码里 `var items []Account` 都会变成：

```go
items := []Account{}
```

这样即使没有任何数据，返回的也是一个 `len == 0` 的非 nil 切片，JSON 编码后就是 `[]`。

## 程序入口

到这一步，handler 写好了、`Server` 类型也定义好了，还差一个真正能跑起来的入口。

`main.go`：

```go
package main

import (
	"database/sql"
	"log"

	"github.com/MorePeanuts/simplebank/api"
	db "github.com/MorePeanuts/simplebank/db/sqlc"
	_ "github.com/lib/pq"
)

const (
	dbDriver      = "postgres"
	dbSource      = "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable"
	serverAddress = "0.0.0.0:8080"
)

func main() {
	conn, err := sql.Open(dbDriver, dbSource)
	if err != nil {
		log.Fatal("connot connect to db:", err)
	}

	store := db.NewStore(conn)
	server := api.NewServer(store)

	err = server.Start(serverAddress)
	if err != nil {
		log.Fatal("cannot start server:", err)
	}
}
```

要点：

- 整个启动流程就是把分层关系顺着一遍："连数据库 → 包 Store → 起 Server → 监听端口"。
- `dbSource` / `serverAddress` 这一刻还是写死的常量，和 [03. CRUD 单元测试](./03_unit_test_for_crud.md#配置测试入口-testmain) 里的 `main_test.go` 里的写法一致。下一节 [07. 配置管理](./07_config_management.md) 会把这些配置改成从 `app.env` 文件读取，避免每个环境都要改源码重新编译。
- `_ "github.com/lib/pq"` 仍然是空导入触发驱动注册，没有它 `sql.Open("postgres", ...)` 会报"unknown driver"。
- `0.0.0.0:8080` 而不是 `localhost:8080`：前者会监听所有网卡，方便后面在 Docker / 容器环境里被外部访问；后者只监听 loopback，容器外面是连不上的。

## 在 Makefile 中加入 `server` 目标

```makefile
server:
	go run main.go

.PHONY: postgres createdb dropdb migrateup migratedown sqlc test server
```

## 用 API 测试平台跑一遍

服务起来之后，可以用 API 测试平台进行测试。

常见的几个选项：

- [Postman](https://www.postman.com/)：生态最成熟，团队协作、Mock Server、自动化测试都齐全；缺点是需要登录、桌面端越来越重，简单接口测试有点过度。
- [Bruno](https://www.usebruno.com/)：开源、本地优先，请求以纯文本（`.bru`）保存在仓库里，可以直接 git 跟踪 —— 对于"接口定义跟着代码一起 review"的工作流非常自然。
- [Insomnia](https://insomnia.rest/)、[Hoppscotch](https://hoppscotch.io/) 等：各有侧重，整体能力相近。

按 RESTful 接口逐个加进去：

| 名称 | 方法 | URL | 说明 |
| ---- | ---- | ---- | ---- |
| `Create Account` | `POST` | `{{baseUrl}}/accounts` | Body 用 `JSON`：`{"owner": "Alice", "currency": "USD"}` |
| `Get Account` | `GET` | `{{baseUrl}}/accounts/:id` | Path 参数 `id` 设成上一步返回的 ID |
| `List Accounts` | `GET` | `{{baseUrl}}/accounts?page_id=1&page_size=5` | Query 参数 `page_id` / `page_size` 在 Bruno 的 Query 面板里填 |


## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| 引入 `gin`，新建 `api` 包 | 在 `Store` 之上加一层 HTTP 入口 |
| `Server` + `errorResponse` | 把"路由注册 / 启动 / 错误响应"这些样板集中在一处 |
| `createAccount` / `getAccount` / `listAccounts` | 暴露三个最基本的 RESTful 接口；用 `binding` 标签做参数校验 |
| `sqlc.yaml` 加 `emit_empty_slices: true` | 列表接口在没有数据时返回 `[]` 而不是 `null`，避免前端类型不一致 |
| `main.go` 新增、Makefile 加 `server` 目标 | 一行 `make server` 就能起服务 |
| 用 Bruno 维护一份 collection 进 git | 接口的"使用者视角"和实现一起被 review，不靠口口相传的 curl |

这一版有几处刻意留到后面处理的简化：
- 数据库连接串、监听地址等配置全是常量 → [07. 配置管理](./07_config_management.md)；
- handler 还没有单元测试 → [08. mock 测试 HTTP API](./08_mock_test_for_http_api.md)；
- `currency` 字段的校验只支持两种货币的硬编码枚举 → [09. 自定义参数校验器](./09_custom_params_validator.md)；
- 数据库唯一键 / 外键违例还混在 500 里 → [10. 处理数据库错误](./10_handle_db_errors.md)。

下一节先把配置管理这一块补上，把 `dbSource` / `serverAddress` 这些常量从源码里搬出去。
