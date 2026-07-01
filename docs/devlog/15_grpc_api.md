# 15. 生成数据库文档，并接入 gRPC 用户接口

[14. 用 refresh token 管理用户会话](./14_refresh_token_session.md) 之后，HTTP 这条线已经能支撑完整的用户登录和会话刷新了。这一节做两件事：先把数据库结构从 DBML 生成成文档和 SQL dump，再给同一套业务补一条 gRPC 入口。

## 从 DBML 生成数据库文档

项目里新增了 `doc/db.dbml`，用 DBML 描述当前数据库结构：

```dbml
Project simple_bank {
  database_type: 'PostgreSQL'
  Note: '''
    # Simple Bank Database
  '''
}

Table users {
  username varchar [pk]
  hashed_password varchar [not null]
  full_name varchar [not null]
  email varchar [unique, not null]
  password_changed_at timestamptz [not null, default: `'0001-01-01 00:00:00Z'`]
  created_at timestamptz [not null, default: `now()`]
}
```

它不是迁移文件的替代品。迁移文件负责让数据库一步步变成目标状态，DBML 更像是一份给人看的结构说明：表、字段、索引、外键都放在一起，读起来比多份 migration 更直接。

这次 DBML 里也包含了上一节新增的 `sessions` 表：

```dbml
Table sessions {
  id uuid [pk]
  username varchar [not null]
  refresh_token varchar [not null]
  user_agent varchar [not null]
  client_ip varchar [not null]
  is_blocked boolean [not null, default: false]
  expires_at timestamptz [not null]
  created_at timestamptz [not null, default: `now()`]
}

Ref: sessions.username > users.username
```

Makefile 新增两个命令：

```makefile
db_docs:
	dbdocs build doc/db.dbml

db_schema:
	dbml2sql --postgres -o doc/schema.sql doc/db.dbml
```

- `make db_docs` 调 `dbdocs`，把 `doc/db.dbml` 发布成可浏览的数据库文档；
- `make db_schema` 调 `dbml2sql`，把同一份 DBML 转成 PostgreSQL SQL dump，输出到 `doc/schema.sql`。

生成出来的 `doc/schema.sql` 是一份完整快照。

## RPC 和 gRPC 是什么

RPC 是 Remote Procedure Call，远程过程调用。它想解决的问题很直接：服务 A 想调用服务 B 的某个能力时，不再手写一段 HTTP 请求、拼 URL、组 JSON、解析响应，而是像调用本地函数一样调用远程函数。

如果用普通 HTTP 接口，调用关系通常长这样：

```text
client
  → POST /users/login
  → JSON body: {"username":"alice","password":"secret"}
  → HTTP 200
  → JSON response: {"access_token":"..."}
```

RPC 会把这件事包装成方法调用：

```go
rsp, err := client.LoginUser(ctx, &pb.LoginUserRequest{
    Username: "alice",
    Password: "secret",
})
```

看起来像本地函数，但底层仍然发生了网络通信：客户端把 request 序列化后发到服务端，服务端反序列化、执行真正的 handler，再把 response 序列化发回来。

这中间通常有几层：

```text
client code
  → client stub：把方法调用编码成网络请求
  → transport：把 bytes 发到服务端
  → server stub：把网络请求还原成方法调用
  → server handler：执行真正业务逻辑
```

所以 RPC 不是让网络消失，而是把网络细节收起来。调用方仍然要处理超时、连接失败、服务端错误、重试这些问题，只是不用在每个接口里重复写 URL 和 JSON 解析。

gRPC 是一套具体的 RPC 框架。它默认使用 Protobuf 定义接口和消息格式，使用 HTTP/2 作为传输层，并能根据 `.proto` 文件生成多种语言的客户端和服务端代码。

它和普通 HTTP/JSON 的差异可以先粗略看成这样：

| 对比项 | HTTP/JSON | gRPC |
| ---- | ---- | ---- |
| 接口契约 | 通常靠文档、路由和 handler 约定 | 写在 `.proto` 文件里 |
| 数据格式 | JSON，文本格式，可读性强 | Protobuf，二进制格式，体积更小 |
| 浏览器直接调用 | 方便 | 原生浏览器支持弱，通常要 gRPC-Web 或网关 |
| 服务间调用 | 能用，但字段和类型容易靠约定 | 更适合强类型内部服务调用 |
| 流式传输 | 需要额外设计 | 内置 unary、server streaming、client streaming、bidirectional streaming |

这一节只用最普通的 unary RPC：客户端发一个 request，服务端回一个 response。它和 `POST /users/login` 的形状很接近，只是接口契约从 Gin handler 转移到了 protobuf 文件。

## 为什么再加一条 gRPC 入口

HTTP API 已经能用，为什么还要 gRPC？因为它解决的是另一类调用场景。

HTTP + JSON 的好处是直观，浏览器、curl、Postman 都能直接调；缺点是接口契约散落在 handler、binding tag 和文档里。gRPC 把契约放到 `.proto` 文件中，request、response、service 方法都先声明，再生成 Go 代码。服务端和客户端都围绕这份声明写代码，少了很多字符串字段名写错、类型猜错的问题。

这一节先不替换 Gin HTTP server，而是让同一个项目同时拥有两套入口：

```text
client
  ├── HTTP/JSON → Gin server → store / token maker
  └── gRPC     → gRPC server → store / token maker
```

业务逻辑仍然落在 Go 代码里，数据库访问仍然走 `db.Store`。gRPC 只是新的传输层。

## 定义 protobuf message

先从用户对象开始。`proto/user.proto`：

```proto
syntax = "proto3";

package pb;

import "google/protobuf/timestamp.proto";

option go_package = "github.com/MorePeanuts/simplebank/pb";

message User {
  string username = 1;
  string full_name = 2;
  string email = 3;
  google.protobuf.Timestamp password_changed_at = 4;
  google.protobuf.Timestamp created_at = 5;
}
```

- `syntax = "proto3"`：指定使用 proto3 语法。proto2 和 proto3 在默认值、optional 字段等细节上不一样，所以文件开头要写清楚；
- `package pb`：protobuf 层面的包名，用来避免不同 proto 文件里的 message 或 service 重名。它不等于 Go 的 package，但会影响生成代码里的命名空间；
- `import "google/protobuf/timestamp.proto"`：引入 protobuf 官方提供的时间类型。没有这行，就不能使用下面的 `google.protobuf.Timestamp`；
- `option go_package = "github.com/MorePeanuts/simplebank/pb"`：告诉 Go 插件生成代码时使用哪个 Go import path；
- `message User`：定义一类消息结构，可以理解成跨语言版本的 struct。

`message User` 里的每一行都是一个字段：

```proto
string username = 1;
```

它由三部分组成：

```text
字段类型 字段名 = 字段编号;
```

`string` 是字段类型，表示字符串；`username` 是字段名，生成 Go 代码后会变成 `Username`；`1` 是字段编号，Protobuf 编码后的二进制数据主要靠这个编号识别字段。字段名可以重命名，字段编号不能随便改。

`password_changed_at` 和 `created_at` 使用 `google.protobuf.Timestamp`，而不是字符串。这样生成 Go 代码后会得到明确的 timestamp 类型，客户端也能按自己的语言生成对应类型。

## 定义注册和登录 RPC

注册接口放在 `proto/rpc_create_user.proto`：

```proto
syntax = "proto3";

package pb;

import "user.proto";

option go_package = "github.com/MorePeanuts/simplebank/pb";

message CreateUserRequest {
  string username = 1;
  string full_name = 2;
  string email = 3;
  string password = 4;
}

message CreateUserResponse {
  User user = 1;
}
```

`CreateUserRequest` 是注册接口的入参：`username`、`full_name`、`email` 最终会写入 `users` 表，`password` 是用户提交的明文密码，只在服务端 hash 时使用，不会原样入库。

`CreateUserResponse` 只有一个 `user` 字段，类型是前面定义的 `User` message。message 可以嵌套使用：一个 response 里放另一个 message，这和 Go struct 里嵌另一个 struct 字段很像。

登录接口放在 `proto/rpc_login_user.proto`：

```proto
syntax = "proto3";

package pb;

import "user.proto";
import "google/protobuf/timestamp.proto";

option go_package = "github.com/MorePeanuts/simplebank/pb";

message LoginUserRequest {
  string username = 1;
  string password = 2;
}

message LoginUserResponse {
  User user = 1;
  string session_id = 2;
  string access_token = 3;
  string refresh_token = 4;
  google.protobuf.Timestamp access_token_expires_at = 5;
  google.protobuf.Timestamp refresh_token_expires_at = 6;
}
```

`LoginUserRequest` 只需要用户名和密码。服务端用 `username` 查用户，再用 `password` 和数据库里的 `hashed_password` 做校验。

这里的 `session_id` 在 Go 代码里原本是 `uuid.UUID`。protobuf 没有内置 UUID 类型，常见做法是用 `string` 保存标准 UUID 文本，或者自己定义 bytes/string 格式约定。当前项目用字符串最简单，Evans 和其他客户端也容易输入和阅读。

最后在 `proto/service_simple_bank.proto` 里声明服务：

```proto
syntax = "proto3";

package pb;

import "rpc_create_user.proto";
import "rpc_login_user.proto";

option go_package = "github.com/MorePeanuts/simplebank/pb";

service SimpleBank {
  rpc CreateUser (CreateUserRequest) returns (CreateUserResponse) {}
  rpc LoginUser (LoginUserRequest) returns (LoginUserResponse) {}
}
```

`service` 定义的是一组 RPC 方法。这里的 `SimpleBank` 类似服务名，生成 Go 代码后会出现 `SimpleBankServer`、`SimpleBankClient` 这类类型。

每一行 `rpc` 都是一条远程方法声明：

```proto
rpc CreateUser (CreateUserRequest) returns (CreateUserResponse) {}
```

意思是：方法名叫 `CreateUser`，接收一个 `CreateUserRequest`，返回一个 `CreateUserResponse`。当前这两个方法都是 unary RPC，也就是一个请求对应一个响应。

## 生成 Go 代码

Makefile 新增 `proto` 命令：

```makefile
proto:
	rm -f pb/*.proto
	protoc --proto_path=proto --go_out=pb --go_opt=paths=source_relative \
		--go-grpc_out=pb --go-grpc_opt=paths=source_relative \
		proto/*.proto
```

`protoc` 做两类生成：

| 参数 | 生成内容 |
| ---- | ---- |
| `--go_out=pb` | message 的 Go struct，例如 `pb.User`、`pb.LoginUserRequest` |
| `--go-grpc_out=pb` | gRPC service 接口和注册函数，例如 `SimpleBankServer`、`RegisterSimpleBankServer` |

`paths=source_relative` 的意思是按 proto 文件名生成到 `pb/` 下，不按 `go_package` 展开多层目录。比如：

```text
proto/user.proto
  → pb/user.pb.go

proto/service_simple_bank.proto
  → pb/service_simple_bank.pb.go
  → pb/service_simple_bank_grpc.pb.go
```

生成代码后，服务端需要实现 `pb.SimpleBankServer` 接口。接口长什么样不用手写，`protoc` 已经根据 `service SimpleBank` 生成好了。

## gRPC server 结构

新增 `gapi/server.go`：

```go
type Server struct {
    pb.UnimplementedSimpleBankServer
    config     util.Config
    store      db.Store
    tokenMaker token.Maker
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

    return server, nil
}
```

这个结构和 `api.Server` 很像：都持有配置、store 和 token maker。区别是 HTTP server 还要保存 Gin router；gRPC server 的路由来自 protobuf 生成的 service 注册。

`pb.UnimplementedSimpleBankServer` 必须嵌进去。它给未来新增 RPC 留了默认实现：当 `.proto` 里加了新方法但服务端还没实现时，编译和运行行为会更明确。生成代码里也会要求实现者嵌入它。

## 启动 gRPC server

配置里把原来的单个 server 地址拆成 HTTP 和 gRPC 两个：

```env
HTTP_SERVER_ADDRESS='0.0.0.0:8080'
GRPC_SERVER_ADDRESS='0.0.0.0:9090'
```

`util.Config` 对应增加字段：

```go
type Config struct {
    DBDriver             string        `mapstructure:"DB_DRIVER"`
    DBSource             string        `mapstructure:"DB_SOURCE"`
    HTTPServerAddress    string        `mapstructure:"HTTP_SERVER_ADDRESS"`
    GRPCServerAddress    string        `mapstructure:"GRPC_SERVER_ADDRESS"`
    TokenSymmetricKey    string        `mapstructure:"TOKEN_SYMMETRIC_KEY"`
    AccessTokenDuration  time.Duration `mapstructure:"ACCESS_TOKEN_DURATION"`
    RefreshTokenDuration time.Duration `mapstructure:"REFRESH_TOKEN_DURATION"`
}
```

`main.go` 里新增 `runGrpcServer`：

```go
func runGrpcServer(config util.Config, store db.Store) {
    server, err := gapi.NewServer(config, store)
    if err != nil {
        log.Fatal("cannot create server:", err)
    }

    grpcServer := grpc.NewServer()
    pb.RegisterSimpleBankServer(grpcServer, server)
    reflection.Register(grpcServer)

    listener, err := net.Listen("tcp", config.GRPCServerAddress)
    if err != nil {
        log.Fatal("cannot create listener")
    }

    log.Printf("start gRPC server at %s", listener.Addr().String())
    err = grpcServer.Serve(listener)
    if err != nil {
        log.Fatal("cannot start gRPC server")
    }
}
```

这段启动流程有四步：

1. 创建业务 server，也就是 `gapi.Server`；
2. 创建底层 `grpc.Server`；
3. 调 `pb.RegisterSimpleBankServer`，把业务实现挂到 gRPC server 上；
4. 监听 `GRPC_SERVER_ADDRESS`，然后 `Serve`。

`reflection.Register(grpcServer)` 是给调试工具用的。开启 reflection 后，像 Evans 这类客户端可以连接到服务端后动态读取服务定义，不必提前拿到编译好的客户端代码。

当前 `main` 里启动的是 gRPC server：

```go
store := db.NewStore(conn)
runGrpcServer(config, store)
```

`runGinServer` 还保留着，只是现在进程启动时选择 gRPC。后面如果要同时跑 HTTP 和 gRPC，需要把其中一个放进 goroutine，再处理退出信号；这一节先不展开。

## 用 Evans 调 gRPC 接口

Makefile 新增 `evans` 命令：

```makefile
evans:
	docker run --rm -it -v "$$(pwd):/mount:ro" -w /mount \
		ghcr.io/ktr0731/evans:latest \
		--path proto/ \
		--proto service_simple_bank.proto \
		--host host.docker.internal \
		--port 9090 \
		repl
```

Evans 是一个 gRPC CLI。这里用 docker 跑它，避免本机单独安装。

几个参数：

| 参数 | 含义 |
| ---- | ---- |
| `-v "$$(pwd):/mount:ro"` | 把当前项目只读挂进容器，Evans 可以读取 `proto/` |
| `-w /mount` | 容器工作目录切到项目根目录 |
| `--path proto/` | proto 文件目录 |
| `--proto service_simple_bank.proto` | 服务入口 proto 文件 |
| `--host host.docker.internal` | 从容器里访问宿主机上的 gRPC server |
| `--port 9090` | 对应 `GRPC_SERVER_ADDRESS` |

启动服务后执行：

```bash
make evans
```

进入 REPL 后就可以选择 package、service，再调用 `CreateUser` 或 `LoginUser`。这条命令对调试很有用：不用写客户端代码，也能检查 proto、server 注册和业务 handler 有没有串起来。

## 数据模型到 protobuf 的转换

gRPC 响应不能直接返回 `db.User`，因为它是 sqlc 生成的数据库模型，里面有 `HashedPassword`，时间字段也是 Go 的 `time.Time`。新增 `gapi/converter.go` 专门做转换：

```go
func convertUser(user db.User) *pb.User {
    return &pb.User{
        Username:          user.Username,
        FullName:          user.FullName,
        Email:             user.Email,
        PasswordChangedAt: timestamppb.New(user.PasswordChangedAt),
        CreatedAt:         timestamppb.New(user.CreatedAt),
    }
}
```

这个函数做了两件事：

- 丢掉 `HashedPassword`；
- 把 `time.Time` 转成 protobuf 的 `Timestamp`。

以后账户、转账、session 这些对象也可以按同样方式放到 converter 里，避免 handler 里到处散落字段映射。

## 实现 `CreateUser`

`gapi/rpc_create_user.go`：

```go
func (server *Server) CreateUser(ctx context.Context, req *pb.CreateUserRequest) (*pb.CreateUserResponse, error) {
    hashedPassword, err := util.HashPassword(req.GetPassword())
    if err != nil {
        return nil, status.Errorf(codes.Internal, "failed to hash password: %s", err)
    }

    arg := db.CreateUserParams{
        Username:       req.GetUsername(),
        HashedPassword: hashedPassword,
        FullName:       req.GetFullName(),
        Email:          req.GetEmail(),
    }

    user, err := server.store.CreateUser(ctx, arg)
    if err != nil {
        if pqErr, ok := err.(*pq.Error); ok {
            switch pqErr.Code.Name() {
            case "unique_violation":
                return nil, status.Errorf(codes.AlreadyExists, "username already exists: %s", err)
            }
        }
        return nil, status.Errorf(codes.Internal, "failed to create user: %s", err)
    }

    rsp := &pb.CreateUserResponse{
        User: convertUser(user),
    }
    return rsp, nil
}
```

流程和 HTTP 的 `createUser` 基本一致：明文密码先 hash，再写入 `users` 表，最后返回不带密码 hash 的用户信息。

错误处理换成了 gRPC 的 `status`：

| 场景 | gRPC code |
| ---- | ---- |
| 密码 hash 失败 | `Internal` |
| 用户名或邮箱违反唯一约束 | `AlreadyExists` |
| 其他数据库错误 | `Internal` |

HTTP 里我们返回状态码和 JSON 错误；gRPC 里返回的是 `error`，客户端可以从 error 中解析出 `codes.AlreadyExists` 这类标准状态。

有一个细节：当前错误文案写的是 `username already exists`，但 `unique_violation` 也可能来自 `email` 的唯一索引。要精确区分的话，需要继续检查 `pqErr.Constraint`。这一节先复用粗粒度处理。

## 实现 `LoginUser`

`gapi/rpc_login_user.go`：

```go
func (server *Server) LoginUser(ctx context.Context, req *pb.LoginUserRequest) (*pb.LoginUserResponse, error) {
    user, err := server.store.GetUser(ctx, req.GetUsername())
    if err != nil {
        if err == sql.ErrNoRows {
            return nil, status.Errorf(codes.NotFound, "user not found")
        }
        return nil, status.Errorf(codes.Internal, "failed to find user")
    }

    err = util.CheckPassword(req.GetPassword(), user.HashedPassword)
    if err != nil {
        return nil, status.Errorf(codes.NotFound, "incorrect password")
    }

    accessToken, accessPayload, err := server.tokenMaker.CreateToken(
        user.Username,
        server.config.AccessTokenDuration,
    )
    if err != nil {
        return nil, status.Errorf(codes.Internal, "failed to create access token")
    }

    refreshToken, refreshPayload, err := server.tokenMaker.CreateToken(
        user.Username,
        server.config.RefreshTokenDuration,
    )
    if err != nil {
        return nil, status.Errorf(codes.Internal, "failed to create refresh token")
    }

    session, err := server.store.CreateSession(ctx, db.CreateSessionParams{
        ID:           refreshPayload.ID,
        Username:     user.Username,
        RefreshToken: refreshToken,
        UserAgent:    "",
        ClientIp:     "",
        IsBlocked:    false,
        ExpiresAt:    refreshPayload.ExpiredAt,
    })
    if err != nil {
        return nil, status.Errorf(codes.Internal, "failed to create session")
    }

    rsp := &pb.LoginUserResponse{
        User:                  convertUser(user),
        SessionId:             session.ID.String(),
        AccessToken:           accessToken,
        RefreshToken:          refreshToken,
        AccessTokenExpiresAt:  timestamppb.New(accessPayload.ExpiredAt),
        RefreshTokenExpiresAt: timestamppb.New(refreshPayload.ExpiredAt),
    }
    return rsp, nil
}
```

这段代码和 HTTP 登录最大的区别是客户端信息暂时为空：

```go
UserAgent: "",
ClientIp:  "",
```

HTTP handler 可以从 Gin context 直接读 `User-Agent` 和 `ClientIP()`；普通 unary gRPC 请求没有同样的高级封装。如果后面要记录这些信息，可以从 gRPC metadata 里读 `user-agent`，客户端 IP 则通常要通过 peer 信息或网关层传进来。这一节先把 session 链路打通。

登录成功后仍然创建 session。也就是说，不管用户从 HTTP 登录还是从 gRPC 登录，refresh token 都会落到同一张 `sessions` 表里，后续撤销和审计可以共用。

错误码方面：

| 场景 | gRPC code |
| ---- | ---- |
| 用户不存在 | `NotFound` |
| 密码错误 | `NotFound` |
| 创建 token 失败 | `Internal` |
| 创建 session 失败 | `Internal` |


## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `doc/db.dbml` | 用 DBML 保存当前数据库结构，方便阅读和生成文档 |
| `make db_docs` | 从 DBML 生成可浏览的数据库文档 |
| `make db_schema` / `doc/schema.sql` | 从 DBML 导出 PostgreSQL schema 快照 |
| `proto/user.proto` | 定义对外返回的用户模型，排除 `hashed_password` |
| `rpc_create_user.proto` / `rpc_login_user.proto` | 定义注册和登录的 request / response |
| `service_simple_bank.proto` | 声明 `SimpleBank` gRPC service |
| `make proto` | 用 `protoc` 生成 message 和 gRPC service Go 代码 |
| `gapi.Server` | 给 gRPC 入口复用 config、store 和 token maker |
| `runGrpcServer` | 在 `0.0.0.0:9090` 启动 gRPC server，并注册 reflection |
| `make evans` | 用 Evans REPL 手动调用 gRPC API |
| `convertUser` | 把数据库模型转换成 protobuf 响应模型 |
| `CreateUser` RPC | 通过 gRPC 完成用户注册，错误映射到 gRPC status code |
| `LoginUser` RPC | 通过 gRPC 完成登录、签发双 token，并创建 session |

到这里，Simple Bank 已经有两套对外入口：HTTP/JSON 适合通用客户端和手工调试，gRPC 适合内部服务和强类型客户端。
