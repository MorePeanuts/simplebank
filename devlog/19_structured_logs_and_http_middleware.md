# 19. 给 gRPC 和 HTTP Gateway 加结构化访问日志

[18. 支持用户信息局部更新，并给 gRPC 接口加授权保护](./18_update_user_and_grpc_authorization.md) 之后，Simple Bank 已经有了公开接口和受保护接口。`CreateUser`、`LoginUser` 可以直接调用，`UpdateUser` 则需要 Bearer token。

接口入口从 Gin HTTP API 切到 gRPC + HTTP Gateway 后，访问日志也要重新处理。

以前使用 Gin 时，框架默认带了 logger middleware。每个 HTTP 请求进来，Gin 会自动输出 method、path、status code、耗时等信息。即使业务代码里没有专门写访问日志，调接口时也能从控制台看到请求记录。

现在主入口换成了 gRPC server 和标准库 `net/http` 启动的 Gateway。它们不会像 Gin 一样自动帮业务接口打印访问日志。项目里之前使用标准库 `log` 的地方，也主要集中在启动、迁移失败、server 监听失败这些流程上，对单次 API 请求没有输出多少有效信息。

这一节把日志换成 `zerolog`，并分别给 gRPC 和 HTTP Gateway 加访问日志。

## 为什么要用结构化日志

普通日志通常长这样：

```text
start gRPC server at [::]:9090
```

人可以读，但机器不太好处理。如果要在日志系统里按 `protocol`、`method`、`status_code`、`duration` 查询，就需要把这些信息拆成字段。

结构化日志更像这样：

```json
{
  "level": "info",
  "protocol": "grpc",
  "method": "/pb.SimpleBank/LoginUser",
  "status_code": 0,
  "status_text": "OK",
  "duration": 1200000,
  "message": "received a gRPC request"
}
```

每个字段都有固定名字，后面接入日志系统时更容易查询和聚合。

这次引入：

```go
github.com/rs/zerolog
```

`zerolog` 默认输出 JSON，适合生产环境。开发环境下再切成 console writer，方便本地直接阅读。

## 用环境变量区分开发日志格式

配置里新增 `ENVIRONMENT`：

```env
ENVIRONMENT='development'
```

`util.Config` 也增加对应字段：

```go
type Config struct {
    Environment          string        `mapstructure:"ENVIRONMENT"`
    DBDriver             string        `mapstructure:"DB_DRIVER"`
    DBSource             string        `mapstructure:"DB_SOURCE"`
    MigrationURL         string        `mapstructure:"MIGRATION_URL"`
    HTTPServerAddress    string        `mapstructure:"HTTP_SERVER_ADDRESS"`
    GRPCServerAddress    string        `mapstructure:"GRPC_SERVER_ADDRESS"`
    TokenSymmetricKey    string        `mapstructure:"TOKEN_SYMMETRIC_KEY"`
    AccessTokenDuration  time.Duration `mapstructure:"ACCESS_TOKEN_DURATION"`
    RefreshTokenDuration time.Duration `mapstructure:"REFRESH_TOKEN_DURATION"`
}
```

启动时读取配置后，根据环境调整 logger：

```go
if config.Environment == "development" {
    log.Logger = log.Output(zerolog.ConsoleWriter{Out: os.Stderr})
}
```

这样本地开发看到的是更友好的彩色文本；非 development 环境继续保留 JSON 输出。

## 把启动日志也换成 zerolog

原来 `main.go` 里使用标准库 `log`：

```go
log.Fatal("cannot load configuration:", err)
log.Println("db migrated successfully")
log.Printf("start gRPC server at %s", listener.Addr().String())
```

现在统一改成 zerolog：

```go
log.Fatal().Err(err).Msg("cannot load configuration")
log.Info().Msg("db migrated successfully")
log.Info().Msgf("start gRPC server at %s", listener.Addr().String())
```

区别是错误会被放进 `error` 字段，而不是拼在 message 里。比如数据库迁移失败时，日志系统可以直接按 `level=error` 或错误字段检索。


## 给 gRPC 加 Unary Interceptor

gRPC 的访问日志适合放在 interceptor 里。

因为当前服务的 RPC 都是 unary RPC：一次请求对应一次响应，所以使用 `grpc.UnaryInterceptor` 就够了。

新增 `gapi/logger.go`：

```go
func GrpcLogger(ctx context.Context, req any, info *grpc.UnaryServerInfo, handler grpc.UnaryHandler) (resp any, err error) {
    startTime := time.Now()
    resp, err = handler(ctx, req)
    duration := time.Since(startTime)

    statusCode := codes.Unknown
    if st, ok := status.FromError(err); ok {
        statusCode = st.Code()
    }

    logger := log.Info()
    if err != nil {
        logger = log.Error().Err(err)
    }

    logger.Str("protocol", "grpc").
        Str("method", info.FullMethod).
        Int("status_code", int(statusCode)).
        Str("status_text", statusCode.String()).
        Dur("duration", duration).
        Msg("received a gRPC request")

    return
}
```

这个函数的调用顺序是：

```text
gRPC request
  → GrpcLogger
    → handler(ctx, req)
      → CreateUser / LoginUser / UpdateUser
    → write log
  → response
```

也就是说，它包在真实 handler 外面。handler 执行前记录开始时间，handler 返回后计算耗时，再根据错误情况写日志。

日志里记录了几个字段：

| 字段 | 含义 |
| ---- | ---- |
| `protocol` | 固定为 `grpc` |
| `method` | RPC 完整方法名，例如 `/pb.SimpleBank/LoginUser` |
| `status_code` | gRPC code 对应的数字 |
| `status_text` | gRPC code 文本，例如 `OK`、`InvalidArgument`、`Unauthenticated` |
| `duration` | 请求处理耗时 |
| `error` | 只有失败请求才带上 |

这样就能看出每个 gRPC 请求调用了哪个方法、结果是什么、耗时多久。

## 注册 gRPC 日志拦截器

原来创建 gRPC server 是：

```go
grpcServer := grpc.NewServer()
```

现在改成：

```go
grpcLogger := grpc.UnaryInterceptor(gapi.GrpcLogger)
grpcServer := grpc.NewServer(grpcLogger)
```

这行代码把 `GrpcLogger` 装进 gRPC server。后面注册到这个 server 上的所有 unary RPC 都会经过这个 interceptor。

## 为什么 HTTP Gateway 还需要单独日志

然而，当前 HTTP Gateway 用的是进程内注册：

```go
err = pb.RegisterSimpleBankHandlerServer(ctx, grpcMux, server)
```

这会把 HTTP/JSON 请求 decode 成 protobuf request，然后直接调用当前进程里的 `gapi.Server` 方法。它不会真的把请求发到 `0.0.0.0:9090` 上的 gRPC server，也就不会经过这里注册的 gRPC interceptor：

```go
grpcLogger := grpc.UnaryInterceptor(gapi.GrpcLogger)
grpcServer := grpc.NewServer(grpcLogger)
```

所以如果只给 gRPC server 加 `GrpcLogger`，只有原生 gRPC 客户端请求会有访问日志。通过 HTTP Gateway 进来的请求虽然也会执行 `CreateUser`、`LoginUser`、`UpdateUser` 这些方法，但不会触发 `GrpcLogger`。

比如客户端请求：

```text
PATCH /v1/update_user
```

实际链路是：

```text
HTTP client
  → http.Serve
  → http.ServeMux
  → grpc-gateway ServeMux
  → gapi.Server.UpdateUser
```

这里没有经过 `grpc.Server`，所以也不会进入 `GrpcLogger`。

因此 HTTP 入口必须在 `http.Serve` 外面再包一层 middleware：

```text
HTTP client
  → HTTPLogger
  → http.ServeMux
  → grpc-gateway ServeMux
  → gapi.Server.UpdateUser
```

这样 Gateway 请求才会有 method、path、HTTP status code 和 duration 日志。Swagger 静态文件也挂在同一个 `http.ServeMux` 上，所以访问 `/swagger/` 时同样会被 HTTP logger 记录。

## 用 ResponseRecorder 捕获 HTTP 状态码

标准库的 `http.ResponseWriter` 可以写响应，但请求结束后不直接告诉 middleware 最终写了什么状态码。

所以新增一个包装类型：

```go
type ResponseRecorder struct {
    http.ResponseWriter
    StatusCode int
    Body       []byte
}
```

它嵌入原始 `http.ResponseWriter`，再额外保存状态码和响应体。

当 handler 调用 `WriteHeader` 时，记录状态码：

```go
func (rec *ResponseRecorder) WriteHeader(statusCode int) {
    rec.StatusCode = statusCode
    rec.ResponseWriter.WriteHeader(statusCode)
}
```

当 handler 写 body 时，记录响应体：

```go
func (rec *ResponseRecorder) Write(body []byte) (int, error) {
    rec.Body = body
    return rec.ResponseWriter.Write(body)
}
```

默认状态码设置成 `http.StatusOK`。这是因为很多 handler 不会显式调用 `WriteHeader(http.StatusOK)`，而是直接 `Write` body。按照 net/http 的规则，这种情况就是 200。

## 实现 HTTP logger middleware

HTTP middleware 写成一个标准的 handler 包装函数：

```go
func HTTPLogger(handler http.Handler) http.Handler {
    return http.HandlerFunc(func(res http.ResponseWriter, req *http.Request) {
        startTime := time.Now()
        rec := &ResponseRecorder{
            ResponseWriter: res,
            StatusCode:     http.StatusOK,
        }
        handler.ServeHTTP(rec, req)
        duration := time.Since(startTime)

        logger := log.Info()
        if rec.StatusCode != http.StatusOK {
            logger = log.Error().Bytes("body", rec.Body)
        }

        logger.Str("protocol", "http").
            Str("method", req.Method).
            Str("path", req.RequestURI).
            Int("status_code", rec.StatusCode).
            Str("status_text", http.StatusText(rec.StatusCode)).
            Dur("duration", duration).
            Msg("received a HTTP request")
    })
}
```

它的执行过程和 gRPC interceptor 类似：

```text
HTTP request
  → HTTPLogger
    → handler.ServeHTTP(rec, req)
      → mux / grpc-gateway / swagger handler
    → write log
  → response
```

非 200 请求会用 error 级别记录，并带上响应体。这样参数错误、未登录、路由不存在这类问题更容易直接从日志里看到原因。

## 把 HTTP middleware 接到 Gateway server

原来 HTTP Gateway 启动时直接把 mux 交给 `http.Serve`：

```go
err = http.Serve(listener, mux)
```

现在改成：

```go
err = http.Serve(listener, gapi.HTTPLogger(mux))
```

这意味着 HTTP Gateway 和 Swagger 静态文件都会经过同一个 HTTP logger：

```text
HTTPLogger
  ├── grpc-gateway routes
  │   ├── POST /v1/create_user
  │   ├── POST /v1/login_user
  │   └── PATCH /v1/update_user
  └── Swagger UI
      └── /swagger/
```

所以访问 API 和访问 Swagger 页面都会有 HTTP 访问日志。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `github.com/rs/zerolog` | 引入结构化日志库 |
| `ENVIRONMENT` | 区分开发环境和其他环境的日志输出格式 |
| `zerolog.ConsoleWriter` | 开发环境输出更易读的控制台日志 |
| 替换标准库 `log` | 启动、迁移、server 错误统一使用结构化日志 |
| `GrpcLogger` | 给 unary gRPC API 记录方法、状态码和耗时 |
| `grpc.UnaryInterceptor` | 把 gRPC logger 接入所有 unary RPC |
| `ResponseRecorder` | 捕获 HTTP 响应状态码和响应体 |
| `HTTPLogger` | 给 HTTP Gateway 和 Swagger 记录访问日志 |
| `http.Serve(listener, gapi.HTTPLogger(mux))` | 在 HTTP server 外层统一套 middleware |

现在 Simple Bank 的两个入口都有了访问日志：gRPC 侧看 RPC 方法和 gRPC code，HTTP 侧看 method、path 和 HTTP status。后续排查接口错误、慢请求或鉴权失败时，不需要只靠客户端反馈，也可以直接从服务端结构化日志里定位。
