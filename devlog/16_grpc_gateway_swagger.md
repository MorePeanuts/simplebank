# 16. 用 gRPC Gateway 复用 gRPC 服务，并生成 Swagger 文档

[15. 生成数据库文档，并接入 gRPC 用户接口](./15_grpc_api.md) 之后，Simple Bank 已经有了一条 gRPC 入口：客户端可以通过 protobuf 生成的强类型代码调用 `CreateUser` 和 `LoginUser`。

但只保留 gRPC 还不够。很多客户端、调试工具和前端页面仍然更习惯 HTTP/JSON；接口文档也不能只靠 `.proto` 文件让人自己读。这一节继续沿着上一节的 gRPC service 往外扩：用 gRPC Gateway 把同一套 gRPC handler 暴露成 HTTP API，再从 proto 自动生成 Swagger 文档，最后把 Swagger 静态文件嵌进 Go server 的二进制里。

最终服务入口变成：

```text
client
  ├── gRPC        → gRPC server  → gapi.Server
  └── HTTP/JSON   → Gateway mux  → gapi.Server
                              └── /swagger/* → embedded swagger UI
```

## 为什么要引入 gRPC Gateway

上一节最后的状态是：

```text
client → gRPC → gapi.Server → store / token maker
```

这对服务间调用很合适，但普通 HTTP 客户端会遇到几个问题：

- 不能直接用 `curl` 按 JSON 调接口；
- 浏览器不能像调用 REST API 一样直接调用原生 gRPC；
- 前端或者第三方调用方更希望看到 HTTP path、request body 和 response schema；
- 如果再单独维护一套 Gin handler，就会出现两份业务逻辑。

gRPC Gateway 根据 proto 文件里的 HTTP annotation 生成一层反向代理代码，把 HTTP/JSON 请求转换成 gRPC request，再调用同一个 gRPC service。

调用链大致是：

```text
POST /v1/login_user
  → grpc-gateway generated handler
  → pb.LoginUserRequest
  → gapi.Server.LoginUser(ctx, req)
  → pb.LoginUserResponse
  → JSON response
```

这样 HTTP 和 gRPC 的入口不一样，但最后落到的 handler 是同一个。

## 在 proto 里声明 HTTP 映射

`proto/service_simple_bank.proto` 先引入 Google API annotation：

```proto
import "google/api/annotations.proto";
```

然后在每个 RPC 方法上加 `google.api.http` 选项：

```proto
service SimpleBank {
  rpc CreateUser (CreateUserRequest) returns (CreateUserResponse) {
    option (google.api.http) = {
      post: "/v1/create_user"
      body: "*"
    };
  }
  rpc LoginUser (LoginUserRequest) returns (LoginUserResponse) {
    option (google.api.http) = {
      post: "/v1/login_user"
      body: "*"
    };
  }
}
```

这段配置的意思是：

| RPC | HTTP method | path | body |
| ---- | ---- | ---- | ---- |
| `CreateUser` | `POST` | `/v1/create_user` | 整个 JSON body 映射到 request |
| `LoginUser` | `POST` | `/v1/login_user` | 整个 JSON body 映射到 request |

`body: "*"` 表示请求体里的所有字段都拿来填充 protobuf request。例如 HTTP 登录请求可以写成：

```json
{
  "username": "alice",
  "password": "secret"
}
```

Gateway 收到后会把它转成 `pb.LoginUserRequest`，再调用 `LoginUser` RPC。

## 生成 Gateway 代码

Makefile 里的 `proto` 命令多了一段：

```makefile
--grpc-gateway_out=pb --grpc-gateway_opt=paths=source_relative
```

它会根据 proto 里的 service 和 HTTP annotation 生成 `pb/service_simple_bank.pb.gw.go`。

这个文件主要是两类代码：

- 把 HTTP request body decode 成 protobuf request；
- 把 HTTP path 注册到 `runtime.ServeMux` 上。

例如生成代码里会出现类似这样的处理函数：

```go
func local_request_SimpleBank_LoginUser_0(ctx context.Context, marshaler runtime.Marshaler, server SimpleBankServer, req *http.Request, pathParams map[string]string) (proto.Message, runtime.ServerMetadata, error) {
    var (
        protoReq LoginUserRequest
        metadata runtime.ServerMetadata
    )
    if err := marshaler.NewDecoder(req.Body).Decode(&protoReq); err != nil && !errors.Is(err, io.EOF) {
        return nil, metadata, status.Errorf(codes.InvalidArgument, "%v", err)
    }
    msg, err := server.LoginUser(ctx, &protoReq)
    return msg, metadata, err
}
```

它最终调用的是 `server.LoginUser(ctx, &protoReq)`。所以 Gateway 不是另一套业务实现，而是 HTTP 到 gRPC handler 的转换层。

## 让 HTTP Gateway 和 gRPC server 同时启动

Gateway 生成代码负责把 HTTP 请求翻译成 gRPC 调用，但真正注册 Gateway handler 时有两种方式。

第一种是进程内翻译：

```go
pb.RegisterSimpleBankHandlerServer(ctx, grpcMux, server)
```

这种方式不经过网络。HTTP 请求进入 Gateway mux 后，生成代码会把 JSON body 解成 protobuf request，然后直接调用当前进程里的 `gapi.Server` 方法。

调用链是：

```text
HTTP client
  → http.ServeMux
  → grpc-gateway ServeMux
  → gapi.Server.LoginUser(ctx, req)
```

第二种是网络转发：

```go
pb.RegisterSimpleBankHandlerFromEndpoint(ctx, grpcMux, config.GRPCServerAddress, opts)
```

这种方式会让 Gateway 作为一个真正的 gRPC client，先把 HTTP 请求翻译成 protobuf request，再通过网络请求 gRPC server。

调用链是：

```text
HTTP client
  → http.ServeMux
  → grpc-gateway ServeMux
  → gRPC client connection
  → grpc.Server
  → gapi.Server.LoginUser(ctx, req)
```

两种方式的区别在于：

| 注册函数 | 调用方式 | 适合场景 |
| ---- | ---- | ---- |
| `RegisterSimpleBankHandlerServer` | 进程内直接调用 service 实现 | Gateway 和 gRPC service 在同一个进程里 |
| `RegisterSimpleBankHandlerFromEndpoint` | 通过 gRPC 连接转发到 server | Gateway 和 gRPC service 分开部署 |

当前项目把 HTTP Gateway 和 gRPC server 放在同一个 Go 进程里，所以选择第一种。这样少一次网络调用，结构也更简单。

`main.go` 里原来只启动 gRPC server：

```go
store := db.NewStore(conn)
runGrpcServer(config, store)
```

现在改成：

```go
store := db.NewStore(conn)
go runGatewayServer(config, store)
runGrpcServer(config, store)
```

`runGrpcServer` 继续监听 `GRPC_SERVER_ADDRESS`，默认是 `0.0.0.0:9090`。Gateway server 监听 `HTTP_SERVER_ADDRESS`，默认是 `0.0.0.0:8080`。

`runGatewayServer` 的核心代码是：

```go
func runGatewayServer(config util.Config, store db.Store) {
    server, err := gapi.NewServer(config, store)
    if err != nil {
        log.Fatal("cannot create server:", err)
    }

    option := runtime.WithMarshalerOption(runtime.MIMEWildcard, &runtime.JSONPb{
        MarshalOptions: protojson.MarshalOptions{
            UseProtoNames: true,
        },
        UnmarshalOptions: protojson.UnmarshalOptions{
            DiscardUnknown: true,
        },
    })

    grpcMux := runtime.NewServeMux(option)

    ctx, cancel := context.WithCancel(context.Background())
    defer cancel()

    err = pb.RegisterSimpleBankHandlerServer(ctx, grpcMux, server)
    if err != nil {
        log.Fatal("cannot register handler server:", err)
    }

    mux := http.NewServeMux()
    mux.Handle("/", grpcMux)

    listener, err := net.Listen("tcp", config.HTTPServerAddress)
    if err != nil {
        log.Fatal("cannot create listener:", err)
    }

    log.Printf("start HTTP gateway server at %s", listener.Addr().String())
    err = http.Serve(listener, mux)
    if err != nil {
        log.Fatal("cannot start HTTP gateway server:", err)
    }
}
```

这里没有再创建 Gin router，而是使用标准库的 `http.NewServeMux()`。

`grpcMux := runtime.NewServeMux(option)` 是 Gateway 的路由器。`pb.RegisterSimpleBankHandlerServer(ctx, grpcMux, server)` 会把生成代码里的 HTTP path 注册进来，并且直接绑定当前的 `gapi.Server`。

## JSON 字段名保持 snake_case

`runtime.NewServeMux` 里传了一个 JSON marshaler 配置：

```go
option := runtime.WithMarshalerOption(runtime.MIMEWildcard, &runtime.JSONPb{
    MarshalOptions: protojson.MarshalOptions{
        UseProtoNames: true,
    },
    UnmarshalOptions: protojson.UnmarshalOptions{
        DiscardUnknown: true,
    },
})
```

`UseProtoNames: true` 的作用是让 HTTP JSON 响应里的字段名使用 proto 里的原始字段名。

例如 `LoginUserResponse` 里有：

```proto
string session_id = 2;
string access_token = 3;
google.protobuf.Timestamp access_token_expires_at = 5;
```

如果不设置 `UseProtoNames`，protobuf JSON 默认可能会转成 camelCase：

```json
{
  "sessionId": "...",
  "accessToken": "...",
  "accessTokenExpiresAt": "..."
}
```

设置以后会保持 snake_case：

```json
{
  "session_id": "...",
  "access_token": "...",
  "access_token_expires_at": "..."
}
```

这和之前 Gin HTTP API 的风格一致，客户端迁移时也更少踩坑。

`DiscardUnknown: true` 则是让 request JSON 里多出来的字段被忽略，而不是直接报错。比如客户端误传了一个暂时不用的字段，服务端仍然可以解析已知字段。

## 从 gRPC metadata 提取客户端信息

上一节的 `LoginUser` RPC 里还有一个遗留问题：创建 session 时 `UserAgent` 和 `ClientIp` 暂时是空字符串。

```go
UserAgent: "",
ClientIp:  "",
```

HTTP handler 可以从 Gin context 里直接读 `User-Agent` 和 `ClientIP()`，但 gRPC handler 只有 `context.Context`。所以这次新增了 `gapi/metadata.go`：

```go
const (
    grpcGatewayUserAgentHeader = "grpcgateway-user-agent"
    userAgentHeader            = "user-agent"
    xForwardedForHeader        = "x-forwarded-for"
)

type Metadata struct {
    UserAgent string
    ClientIP  string
}

func (server *Server) extractMetadata(ctx context.Context) *Metadata {
    mtdt := &Metadata{}

    if md, ok := metadata.FromIncomingContext(ctx); ok {
        if userAgents := md.Get(grpcGatewayUserAgentHeader); len(userAgents) > 0 {
            mtdt.UserAgent = userAgents[0]
        }

        if userAgents := md.Get(userAgentHeader); len(userAgents) > 0 {
            mtdt.UserAgent = userAgents[0]
        }

        if clientIPs := md.Get(xForwardedForHeader); len(clientIPs) > 0 {
            mtdt.ClientIP = clientIPs[0]
        }
    }

    if p, ok := peer.FromContext(ctx); ok {
        mtdt.ClientIP = p.Addr.String()
    }

    return mtdt
}
```

这里分两步取信息。

第一步从 gRPC metadata 里取 header：

| header | 来源 | 用途 |
| ---- | ---- | ---- |
| `grpcgateway-user-agent` | gRPC Gateway 转发 HTTP 请求时带入 | 记录原始 HTTP 客户端的 User-Agent |
| `user-agent` | 原生 gRPC 客户端 metadata | 记录 gRPC 客户端标识 |
| `x-forwarded-for` | 代理或网关层传入 | 记录真实客户端 IP |

第二步从 `peer.FromContext(ctx)` 里取对端地址：

```go
if p, ok := peer.FromContext(ctx); ok {
    mtdt.ClientIP = p.Addr.String()
}
```

这能拿到当前连接对端的地址。对于原生 gRPC 请求，它通常就是客户端连接地址；对于经过代理或 Gateway 的请求，它可能是代理地址。当前实现最后用 `peer` 覆盖 `ClientIP`，所以更偏向记录实际连接来源。如果以后要优先记录代理传来的真实客户端 IP，可以把 `x-forwarded-for` 的优先级放到 `peer` 后面处理。

`LoginUser` 里就可以这样使用：

```go
mtdt := server.extractMetadata(ctx)
session, err := server.store.CreateSession(ctx, db.CreateSessionParams{
    ID:           refreshPayload.ID,
    Username:     user.Username,
    RefreshToken: refreshToken,
    UserAgent:    mtdt.UserAgent,
    ClientIp:     mtdt.ClientIP,
    IsBlocked:    false,
    ExpiresAt:    refreshPayload.ExpiredAt,
})
```

这样无论登录请求来自 gRPC 还是 HTTP Gateway，session 表里都能尽量记录客户端信息。

## 从 proto 生成 Swagger 文档

HTTP API 能访问之后，还需要一份文档。既然 HTTP path 已经写在 proto 里，就可以继续从 proto 生成 OpenAPI / Swagger 文件。

`proto/service_simple_bank.proto` 引入 openapiv2 annotation：

```proto
import "protoc-gen-openapiv2/options/annotations.proto";
```

然后给整个 API 加 Swagger 信息：

```proto
option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_swagger) = {
  info: {
    title: "Simple Bank API"
    version: "1.1"
    contact: {
      name: "MorePeanuts"
      url: "https://github.com/MorePeanuts/simplebank"
      email: "liaofeng0203@gmail.com"
    }
  }
};
```

每个 RPC 也补上 operation 描述：

```proto
rpc CreateUser (CreateUserRequest) returns (CreateUserResponse) {
  option (google.api.http) = {
    post: "/v1/create_user"
    body: "*"
  };
  option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_operation) = {
    description: "Use this API to create a new user"
    summary: "Create new user"
  };
}
```

`LoginUser` 同理：

```proto
rpc LoginUser (LoginUserRequest) returns (LoginUserResponse) {
  option (google.api.http) = {
    post: "/v1/login_user"
    body: "*"
  };
  option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_operation) = {
    description: "Use this API to login user and get access token & refresh token"
    summary: "Login user"
  };
}
```

这样 proto 就不只是 gRPC 的接口定义，也成了 HTTP 文档的源头。

Makefile 继续扩展 `proto` 命令：

```makefile
--openapiv2_out=doc/swagger --openapiv2_opt=allow_merge=true,merge_file_name=simple_bank
```

含义是：

- `--openapiv2_out=doc/swagger`：把 Swagger JSON 输出到 `doc/swagger`；
- `allow_merge=true`：允许把多个 proto 里的 API 合并成一份文档；
- `merge_file_name=simple_bank`：生成文件名为 `simple_bank.swagger.json`。

执行：

```bash
make proto
```

会同时生成：

| 文件 | 来源 | 用途 |
| ---- | ---- | ---- |
| `pb/*.pb.go` | protobuf message | Go message 类型 |
| `pb/*_grpc.pb.go` | service definition | gRPC server / client 接口 |
| `pb/*.pb.gw.go` | HTTP annotation | HTTP Gateway handler |
| `doc/swagger/simple_bank.swagger.json` | openapiv2 annotation | Swagger / OpenAPI 文档 |

这一步把代码生成链路集中到了同一个命令里，避免手动更新其中一部分导致文档和服务不一致。

## 先用文件目录提供 Swagger UI

生成 Swagger JSON 之后，还需要一个页面展示它。这里使用的是 Swagger UI，它本质上是一组前端静态文件：HTML、CSS、JavaScript、图片资源，再加上一份配置文件告诉页面去加载哪个 Swagger JSON。

这组静态文件来自 `swagger-ui-dist`：

```bash
npm install swagger-ui-dist
```

安装后，`node_modules/swagger-ui-dist` 目录里会有一份可以直接部署的 Swagger UI 文件，例如：

```text
index.html
swagger-ui.css
swagger-ui-bundle.js
swagger-ui-standalone-preset.js
swagger-initializer.js
favicon-16x16.png
favicon-32x32.png
```

项目把这些文件复制到 `doc/swagger`，和生成出来的 `simple_bank.swagger.json` 放在同一个目录下：

```text
doc/swagger
  ├── index.html
  ├── swagger-ui.css
  ├── swagger-ui-bundle.js
  ├── swagger-ui-standalone-preset.js
  ├── swagger-initializer.js
  └── simple_bank.swagger.json
```

默认的 `swagger-initializer.js` 通常会加载在线示例地址。这里要把它改成本地生成的 Swagger JSON：

```js
window.ui = SwaggerUIBundle({
  url: "simple_bank.swagger.json",
  dom_id: '#swagger-ui',
  deepLinking: true,
  presets: [
    SwaggerUIBundle.presets.apis,
    SwaggerUIStandalonePreset
  ],
  plugins: [
    SwaggerUIBundle.plugins.DownloadUrl
  ],
  layout: "StandaloneLayout"
});
```

因为 `swagger-initializer.js` 和 `simple_bank.swagger.json` 在同一个目录里，所以这里直接写相对路径 `simple_bank.swagger.json`。这样页面不依赖外部网络，也不会打开 Swagger 官方的示例 API。

最直接的提供方式是用标准库把 `doc/swagger` 目录挂出来：

```go
fs := http.FileServer(http.Dir("./doc/swagger"))
mux.Handle("/swagger/", http.StripPrefix("/swagger/", fs))
```

启动 server 后访问：

```text
/swagger/
```

就能看到 Swagger UI 页面。页面会加载同目录下的 `simple_bank.swagger.json`，展示 `CreateUser` 和 `LoginUser` 两个接口。

这种方式开发时很直观，但它依赖运行目录里必须存在 `doc/swagger`。如果只把 Go server 编译成一个二进制文件拿去部署，而没有带上这个目录，`/swagger/` 就会失效。

所以还需要最后一步：把静态文件嵌进二进制。

## 用 statik 嵌入 Swagger 静态文件

项目引入了 `github.com/rakyll/statik`，并在 `tools/tools.go` 里记录工具依赖：

```go
package tools

import (
    _ "github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-grpc-gateway"
    _ "github.com/grpc-ecosystem/grpc-gateway/v2/protoc-gen-openapiv2"
    _ "github.com/rakyll/statik"
    _ "google.golang.org/grpc/cmd/protoc-gen-go-grpc"
    _ "google.golang.org/protobuf/cmd/protoc-gen-go"
)
```

`tools.go` 不是业务代码。它的作用是把这些命令行工具纳入 Go module 管理，避免只在某个人的机器上装过，换一台机器就不知道该装哪个版本。

Makefile 的 `proto` 命令最后加上：

```makefile
statik -src=./doc/swagger -dest=./doc
```

执行后会生成：

```text
doc/statik/statik.go
```

这个 Go 文件里包含了 `doc/swagger` 目录下所有静态资源的压缩数据。只要这个文件被编译进 server，Swagger UI 就不再依赖外部目录。

`main.go` 里用 blank import 触发注册：

```go
import (
    _ "github.com/MorePeanuts/simplebank/doc/statik"
)
```

然后把原来的文件目录替换成 statik 文件系统：

```go
statikFS, err := fs.New()
if err != nil {
    log.Fatal("cannot create statik file system:", err)
}

swaggerHandler := http.StripPrefix("/swagger/", http.FileServer(statikFS))
mux.Handle("/swagger/", swaggerHandler)
```

`fs.New()` 返回的是 statik 注册过的虚拟文件系统。`http.FileServer(statikFS)` 和普通文件服务器的使用方式一样，只是文件来源不再是磁盘目录，而是编译进二进制的数据。

这样部署时只需要一个 server binary，Swagger 页面也能正常访问。

## 当前请求链路

现在启动服务后，会同时监听两个端口：

| 地址 | 协议 | 入口 |
| ---- | ---- | ---- |
| `0.0.0.0:9090` | gRPC | `runGrpcServer` |
| `0.0.0.0:8080` | HTTP/JSON | `runGatewayServer` |

注册用户可以走 gRPC：

```text
SimpleBank.CreateUser(CreateUserRequest)
```

也可以走 HTTP：

```text
POST /v1/create_user
```

登录同理：

```text
SimpleBank.LoginUser(LoginUserRequest)
POST /v1/login_user
```

两条路最终都会进入 `gapi.Server`：

```text
gRPC client
  → grpc.Server
  → gapi.Server.CreateUser / LoginUser

HTTP client
  → http.ServeMux
  → grpc-gateway ServeMux
  → gapi.Server.CreateUser / LoginUser
```

这就是这一节的核心收益：接口协议变多了，但业务实现没有变多。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `google.api.http` annotation | 在 proto 里声明 RPC 到 HTTP path 的映射 |
| `protoc-gen-grpc-gateway` | 生成 HTTP/JSON 到 gRPC handler 的转换代码 |
| `runGatewayServer` | 在 `0.0.0.0:8080` 提供 HTTP Gateway 服务 |
| `UseProtoNames: true` | 让 JSON 字段名保持 proto 的 snake_case 风格 |
| `extractMetadata` | 从 gRPC metadata / peer 中提取 user agent 和 client IP |
| `protoc-gen-openapiv2` | 从 proto 自动生成 Swagger JSON |
| Swagger UI 静态文件 | 提供可浏览、可调试的接口文档页面 |
| `statik` | 把 Swagger 静态文件嵌入 Go 二进制 |
| `tools/tools.go` | 把代码生成工具纳入 Go module 版本管理 |

到这里，Simple Bank 的 API 入口已经从单一 gRPC 扩展成 gRPC + HTTP/JSON + Swagger 文档。后续再新增接口时，只要先更新 proto，再执行 `make proto`，gRPC 代码、HTTP Gateway 和 Swagger 文档就能一起更新。
