# 17. 给 gRPC 补参数校验，并把数据库迁移移进 Go 进程

[16. 用 gRPC Gateway 复用 gRPC 服务，并生成 Swagger 文档](./16_grpc_gateway_swagger.md) 之后，请求入口已经从单一 gRPC 变成了 gRPC + HTTP Gateway。`CreateUser` 和 `LoginUser` 两个接口可以被 Evans 调，也可以通过 `/v1/create_user`、`/v1/login_user` 走 HTTP/JSON。

这一节继续收两个尾巴：

1. gRPC handler 还没有像 Gin HTTP API 那样做参数校验，错误信息也不够适合客户端展示；
2. 容器启动时仍然依赖 `start.sh` 调 `migrate` 命令行工具，迁移逻辑散在 Go 进程外面。

## 为什么 gRPC 也要单独做校验

Gin HTTP API 里，参数校验主要靠 struct tag 和自定义 validator。比如注册用户时，`username`、`password`、`email` 这些字段会在 handler 入口就被检查。

gRPC 这边不走 Gin binding。Gateway 收到 JSON 后只负责把 body decode 成 protobuf request，再调用 `gapi.Server.CreateUser` 或 `gapi.Server.LoginUser`。如果 handler 里不校验，空字符串、格式错误的邮箱、过短的密码都会继续往后走，直到数据库或业务逻辑报错。

这有两个问题。

第一，错误位置太靠后。比如空用户名可能最后变成数据库错误，客户端看不出到底是哪一个字段错了。

第二，HTTP Gateway 和原生 gRPC 都复用同一个 gRPC handler，所以校验应该放在 `gapi` 层，而不是只放在 Gateway 外面。这样无论请求从哪条路进来，规则都是同一套。

## 抽出通用校验函数

新增 `val/validator.go`，把字段级别的规则放到一个独立 package 里：

```go
package val

import (
    "fmt"
    "net/mail"
    "regexp"
)

var (
    isValidUsername = regexp.MustCompile(`^[a-z0-9_]+$`).MatchString
    isValidFullName = regexp.MustCompile(`^[a-zA-Z\s]+$`).MatchString
)
```

用户名和姓名使用正则检查：

```go
func ValidateUsername(value string) error {
    if err := ValidateString(value, 3, 100); err != nil {
        return err
    }
    if !isValidUsername(value) {
        return fmt.Errorf("must contain only lowercase letters, digits, or underscore")
    }
    return nil
}
```

当前用户名规则比较明确：

- 长度 3 到 100；
- 只能包含小写字母、数字和下划线。

密码先只校验长度：

```go
func ValidatePassword(value string) error {
    return ValidateString(value, 6, 100)
}
```

邮箱用标准库 `net/mail` 解析：

```go
func ValidateEmail(value string) error {
    if err := ValidateString(value, 3, 200); err != nil {
        return err
    }
    if _, err := mail.ParseAddress(value); err != nil {
        return fmt.Errorf("is not a valid email address")
    }
    return nil
}
```

这里没有把规则写进 protobuf tag。protobuf 本身只定义字段类型，不负责业务校验。把校验放在 Go package 里更直接，也方便后面给 HTTP、gRPC、测试共用。

## 在 gRPC 错误里返回字段详情

普通的 gRPC 错误可以这样返回：

```go
return nil, status.Errorf(codes.InvalidArgument, "invalid parameters")
```

这能告诉客户端请求参数不对，但还不够。客户端还需要知道哪个字段错了、为什么错。

gRPC 支持在 `status` 里附加结构化 details。这里新增 `gapi/error.go`：

```go
func fieldViolation(field string, err error) *errdetails.BadRequest_FieldViolation {
    return &errdetails.BadRequest_FieldViolation{
        Field:       field,
        Description: err.Error(),
    }
}
```

每个字段错误都会转成一个 `BadRequest_FieldViolation`。例如用户名为空时，服务端可以返回：

```text
field: username
description: must contain from 3-100 characters
```

再把所有字段错误包进 `BadRequest`：

```go
func invalidArgumentError(violations []*errdetails.BadRequest_FieldViolation) error {
    badRequest := &errdetails.BadRequest{
        FieldViolations: violations,
    }
    statusInvalid := status.New(codes.InvalidArgument, "invalid parameters")

    statusDetails, err := statusInvalid.WithDetails(badRequest)
    if err != nil {
        return statusInvalid.Err()
    }

    return statusDetails.Err()
}
```

`status.New(codes.InvalidArgument, "invalid parameters")` 是主错误。`WithDetails(badRequest)` 把字段级错误挂上去。

客户端拿到 error 后，既能看到标准的 gRPC code：

```text
InvalidArgument
```

也能解析出 details 里的字段列表。机器可以按字段展示错误，人也能直接读 description。

## 校验 `CreateUser` 请求

`CreateUser` 一进来先调用 `validateCreateUserRequest`：

```go
func (server *Server) CreateUser(ctx context.Context, req *pb.CreateUserRequest) (*pb.CreateUserResponse, error) {
    violations := validateCreateUserRequest(req)
    if violations != nil {
        return nil, invalidArgumentError(violations)
    }

    hashedPassword, err := util.HashPassword(req.GetPassword())
    ...
}
```

校验函数逐个检查字段：

```go
func validateCreateUserRequest(req *pb.CreateUserRequest) (violations []*errdetails.BadRequest_FieldViolation) {
    if err := val.ValidateUsername(req.GetUsername()); err != nil {
        violations = append(violations, fieldViolation("username", err))
    }

    if err := val.ValidatePassword(req.GetPassword()); err != nil {
        violations = append(violations, fieldViolation("password", err))
    }

    if err := val.ValidateFullName(req.GetFullName()); err != nil {
        violations = append(violations, fieldViolation("full_name", err))
    }

    if err := val.ValidateEmail(req.GetEmail()); err != nil {
        violations = append(violations, fieldViolation("email", err))
    }

    return
}
```

这里没有遇到第一个错误就直接返回，而是把所有字段错误都收集起来。这样客户端一次请求就能拿到完整列表，不用修一个字段、提交一次、再发现下一个字段也错了。

例如请求体是：

```json
{
  "username": "A!",
  "password": "123",
  "full_name": "L3o",
  "email": "bad-email"
}
```

服务端可以一次返回四个 field violation。对表单页面来说，这比只返回第一条错误更好用。

## 校验 `LoginUser` 请求

登录接口只需要用户名和密码，所以校验更短：

```go
func validateLoginUserRequest(req *pb.LoginUserRequest) (violations []*errdetails.BadRequest_FieldViolation) {
    if err := val.ValidateUsername(req.GetUsername()); err != nil {
        violations = append(violations, fieldViolation("username", err))
    }

    if err := val.ValidatePassword(req.GetPassword()); err != nil {
        violations = append(violations, fieldViolation("password", err))
    }

    return
}
```

`LoginUser` 入口同样先检查参数：

```go
violations := validateLoginUserRequest(req)
if violations != nil {
    return nil, invalidArgumentError(violations)
}
```

校验通过后，才会查用户、检查密码、签发 token、创建 session。

这让错误分层更清楚：

| 场景 | gRPC code |
| ---- | ---- |
| 请求字段格式不对 | `InvalidArgument` |
| 用户不存在 | `NotFound` |
| 密码错误 | `NotFound` |
| 数据库或 token 内部错误 | `Internal` |

`InvalidArgument` 是客户端可以自己修的错误；`Internal` 是服务端问题。把这两类分开，日志和客户端处理都会简单一些。

## 之前的迁移方式有什么问题

容器化那一节里，迁移是在 `start.sh` 里做的：

```sh
echo "run db migration"
/app/migrate -path /app/migration -database "$DB_SOURCE" -verbose up

echo "start the app"
exec "$@"
```

这个方案能跑，但有几个不舒服的地方。

第一，运行镜像里要额外放一个 `migrate` CLI。Dockerfile 需要在 builder 里用 `curl` 下载 release 包，再复制到 run stage。构建步骤变多了，镜像里也多了一个运行时其实不属于业务服务的二进制。

第二，迁移目录被复制到 `/app/migration`，而 Go 服务自己的项目路径是 `db/migration`。脚本、Dockerfile、本地开发对迁移目录的叫法不一致。

第三，迁移失败时，日志来自 shell 脚本和外部命令。服务启动逻辑被拆成两段：先 shell，再 Go。现在项目已经把 server 启动、配置读取都放在 `main.go` 里，迁移也可以收回来。

## 用 Go 代码执行 migration

这次直接引入 `github.com/golang-migrate/migrate/v4`：

```go
import (
    "github.com/golang-migrate/migrate/v4"
    _ "github.com/golang-migrate/migrate/v4/database/postgres"
    _ "github.com/golang-migrate/migrate/v4/source/file"
)
```

两个 blank import 很关键：

| import | 作用 |
| ---- | ---- |
| `database/postgres` | 注册 PostgreSQL database driver |
| `source/file` | 注册 `file://` migration source |

没有它们，`migrate.New(migrationURL, dbSource)` 不知道怎么处理 PostgreSQL 连接串，也不知道怎么读取本地迁移目录。

配置里新增 `MIGRATION_URL`：

```env
MIGRATION_URL='file://db/migration'
```

`util.Config` 也加对应字段：

```go
type Config struct {
    DBDriver     string `mapstructure:"DB_DRIVER"`
    DBSource     string `mapstructure:"DB_SOURCE"`
    MigrationURL string `mapstructure:"MIGRATION_URL"`
    ...
}
```

然后在 `main` 里打开数据库连接后，先执行迁移：

```go
conn, err := sql.Open(config.DBDriver, config.DBSource)
if err != nil {
    log.Fatal("connot connect to db:", err)
}

runDBMigration(config.MigrationURL, config.DBSource)

store := db.NewStore(conn)
go runGatewayServer(config, store)
runGrpcServer(config, store)
```

`runDBMigration` 很短：

```go
func runDBMigration(migrationURL string, dbSource string) {
    migration, err := migrate.New(migrationURL, dbSource)
    if err != nil {
        log.Fatal("cannot create new migrate instance:", err)
    }

    if err = migration.Up(); err != nil && err != migrate.ErrNoChange {
        log.Fatal("failed to run migrate up:", err)
    }

    log.Println("db migrated successfully")
}
```

这里特意忽略 `migrate.ErrNoChange`。如果数据库已经是最新版本，`migration.Up()` 会返回这个错误。对服务启动来说，这不是失败，只能说明没有新的迁移要跑。

所以启动结果有两种正常情况：

| 数据库状态 | 行为 |
| ---- | ---- |
| 还没建表或版本落后 | 执行缺失的 migration |
| 已经是最新版本 | 返回 `ErrNoChange`，继续启动服务 |

真正需要中断启动的是迁移文件读不到、数据库连不上、SQL 执行失败这类错误。

## Dockerfile 顺手做了一次构建缓存优化

迁移移进 Go 进程后，Dockerfile 不再需要下载 `migrate` CLI：

```dockerfile
RUN apk add --no-cache curl
RUN curl -L https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz | tar xvz
```

这两行可以删掉，run stage 也不用再复制 `/app/migrate`。

同时，builder 阶段改成先复制 `go.mod` 和 `go.sum`：

```dockerfile
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o main main.go
```

这和原来的写法不一样。

原来是：

```dockerfile
COPY . .
RUN go build -o main main.go
```

只要任何源码文件变化，`COPY . .` 这一层缓存就失效，后面的 `go build` 需要重新执行。改成先 `COPY go.mod go.sum ./` 后，依赖下载单独变成一层。只要依赖文件没变，`go mod download` 就能复用 Docker 缓存。

平时改业务代码时，Docker 构建大概会从这里开始重新跑：

```dockerfile
COPY . .
RUN go build -o main main.go
```

依赖层不用重新下载。

run stage 里迁移目录也改回项目里的路径：

```dockerfile
COPY db/migration ./db/migration
```

这样它和 `MIGRATION_URL='file://db/migration'` 对得上。

## `start.sh` 只负责交给主进程

现在 `start.sh` 里不再跑迁移：

```sh
#!/bin/sh

set -e

echo "start the app"
exec "$@"
```

它还保留着，是因为 `ENTRYPOINT [ "/app/start.sh" ]` 这套结构仍然有用。`exec "$@"` 会把 shell 进程替换成 `/app/main`，让 Go 二进制成为容器里的主进程，继续正常接收 docker 发来的停止信号。

迁移逻辑从脚本移到 Go 以后，启动顺序更集中：

```text
start.sh
  → exec /app/main
    → LoadConfig
    → sql.Open
    → runDBMigration
    → runGatewayServer
    → runGrpcServer
```

以后如果要在启动阶段加更多检查，比如检查 Redis、加载证书、初始化后台任务，也可以继续放在 Go 入口里统一处理。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `val/validator.go` | 抽出用户名、密码、姓名、邮箱的通用校验规则 |
| `gapi/error.go` | 用 `errdetails.BadRequest` 返回字段级 gRPC 参数错误 |
| `validateCreateUserRequest` | 注册用户前一次性收集所有字段错误 |
| `validateLoginUserRequest` | 登录前校验用户名和密码格式 |
| `codes.InvalidArgument` | 把参数错误和业务错误、内部错误区分开 |
| `github.com/golang-migrate/migrate/v4` | 在 Go 进程内执行数据库迁移 |
| `MIGRATION_URL` | 配置迁移文件来源，默认读取 `file://db/migration` |
| `runDBMigration` | 服务启动时先执行 migration，忽略 `ErrNoChange` |
| Dockerfile 依赖缓存 | 只在 `go.mod` / `go.sum` 变化时重新下载 Go 依赖 |
| 精简 `start.sh` | shell 只负责 `exec` 主进程，不再承载迁移逻辑 |

到这里，gRPC API 的请求入口更像一个正式接口了：参数错误有明确字段，业务错误有标准 code。容器启动也更干净，迁移和服务启动都收在 Go 入口里，Docker 镜像不用再额外打包 migrate CLI。
