# 18. 支持用户信息局部更新，并给 gRPC 接口加授权保护

[17. 给 gRPC 补参数校验，并把数据库迁移移进 Go 进程](./17_grpc_validation_and_db_migration.md) 之后，gRPC 入口已经有了比较完整的参数校验和错误返回。`CreateUser`、`LoginUser` 这两个接口也可以同时通过 gRPC 和 HTTP Gateway 调用。

这一节继续补用户资料更新能力。

## 为什么更新用户不能简单覆盖所有字段

注册用户时，`CreateUser` 会一次性写入用户名、密码、姓名和邮箱。但更新用户资料时，客户端通常只想改其中一部分字段。

比如只修改邮箱：

```json
{
  "username": "alice",
  "email": "alice_new@example.com"
}
```

这个请求不应该把 `full_name` 或 `hashed_password` 清空。也就是说，更新接口需要能表达两件事：

| 状态 | 含义 |
| ---- | ---- |
| 字段没传 | 保持数据库原值 |
| 字段传了 | 用新值覆盖数据库原值 |

普通的字符串参数很难表达这个差异。空字符串既可能表示“用户真的想更新成空字符串”，也可能表示“客户端没有传这个字段”。

所以这次从数据库 SQL、sqlc 参数、protobuf request 三层一起处理“局部更新”。

## 用 `sqlc.narg` 生成可空更新参数

数据库查询里新增 `UpdateUser`：

```sql
-- name: UpdateUser :one
UPDATE users
SET
  hashed_password = COALESCE(sqlc.narg(hashed_password), hashed_password),
  password_changed_at = COALESCE(sqlc.narg(password_changed_at), password_changed_at),
  full_name = COALESCE(sqlc.narg(full_name), full_name),
  email = COALESCE(sqlc.narg(email), email)
WHERE
  username = sqlc.arg(username)
RETURNING *;
```

这里有两个关键点。

第一，使用 `sqlc.narg(...)`。它会让 sqlc 生成 `sql.NullString`、`sql.NullTime` 这类 nullable 参数，而不是普通字符串或时间。

第二，使用 `COALESCE(new_value, old_value)`。如果传入的新值是 `NULL`，就保留原字段；如果新值不是 `NULL`，就更新成新值。

生成后的参数大致是：

```go
type UpdateUserParams struct {
    HashedPassword    sql.NullString `json:"hashed_password"`
    PasswordChangedAt sql.NullTime   `json:"password_changed_at"`
    FullName          sql.NullString `json:"full_name"`
    Email             sql.NullString `json:"email"`
    Username          string         `json:"username"`
}
```

调用方通过 `Valid` 控制字段是否参与更新：

```go
FullName: sql.NullString{
    String: newFullName,
    Valid:  true,
}
```

如果 `Valid` 是 `false`，这个字段传到 SQL 里就是 `NULL`，最后会被 `COALESCE` 替换回原值。

## 给局部更新补测试

数据库层新增了几组测试，分别覆盖只更新单个字段和一次更新所有字段：

```go
func TestUpdateUserOnlyFullName(t *testing.T) {
    oldUser := createRandomUser(t)

    newFullName := util.RandomOwner()
    updatedUser, err := testQueries.UpdateUser(context.Background(), UpdateUserParams{
        Username: oldUser.Username,
        FullName: sql.NullString{
            String: newFullName,
            Valid:  true,
        },
    })

    require.NoError(t, err)
    require.NotEqual(t, oldUser.FullName, updatedUser.FullName)
    require.Equal(t, newFullName, updatedUser.FullName)
    require.Equal(t, oldUser.Email, updatedUser.Email)
    require.Equal(t, oldUser.HashedPassword, updatedUser.HashedPassword)
}
```

这类测试不只检查目标字段确实变了，也检查其他字段没有被误改。

对应场景包括：

| 测试 | 目标 |
| ---- | ---- |
| `TestUpdateUserOnlyFullName` | 只更新姓名 |
| `TestUpdateUserOnlyEmail` | 只更新邮箱 |
| `TestUpdateUserOnlyPassword` | 只更新密码哈希 |
| `TestUpdateUserAllFields` | 同时更新姓名、邮箱和密码 |

同时，Makefile 的 `sqlc` 命令里顺手加上 `mockgen`：

```makefile
sqlc:
    sqlc generate
    mockgen -package mockdb -destination db/mock/store.go github.com/MorePeanuts/simplebank/db/sqlc Store
```

这样每次重新生成 sqlc 代码后，mock store 也会一起更新。否则新增 `UpdateUser` 方法后，测试里使用的 mock 接口容易落后。

## 在 protobuf 里使用 optional 字段

数据库层能处理 nullable 参数之后，gRPC request 也要能表达字段是否传入。

新增 `proto/rpc_update_user.proto`：

```proto
message UpdateUserRequest {
  string username = 1;
  optional string full_name = 2;
  optional string email = 3;
  optional string password = 4;
}

message UpdateUserResponse {
  User user = 1;
}
```

这里 `username` 仍然是普通字段，因为服务端需要知道要更新哪个用户。

`full_name`、`email`、`password` 都是 `optional`。生成 Go 代码后，这些字段会变成指针：

```go
FullName *string
Email    *string
Password *string
```

于是服务端可以直接判断：

```go
Valid: req.FullName != nil
```

这和数据库层的 `sql.NullString.Valid` 正好对上。

## 注册 `UpdateUser` RPC 和 HTTP Gateway 路由

`service_simple_bank.proto` 里引入新的 request 文件，并把 API 版本从 `1.1` 提到 `1.2`：

```proto
import "rpc_update_user.proto";
```

然后在 service 里新增 RPC：

```proto
rpc UpdateUser (UpdateUserRequest) returns (UpdateUserResponse) {
  option (google.api.http) = {
    patch: "/v1/update_user"
    body: "*"
  };
  option (grpc.gateway.protoc_gen_openapiv2.options.openapiv2_operation) = {
    description: "Use this API to update user"
    summary: "Update user"
  };
}
```

这里使用 `PATCH`，因为这个接口的语义就是局部更新。请求可以来自原生 gRPC，也可以来自 HTTP Gateway：

```text
SimpleBank.UpdateUser(UpdateUserRequest)
PATCH /v1/update_user
```

执行 `make proto` 后，相关代码和文档都会重新生成。

## 实现 gRPC 更新逻辑

`gapi/rpc_update_user.go` 里新增 `UpdateUser` handler。

入口先做参数校验：

```go
violations := validateUpdateUserRequest(req)
if violations != nil {
    return nil, invalidArgumentError(violations)
}
```

校验函数里，`username` 必填，其他字段只有在传入时才校验：

```go
if req.Password != nil {
    if err := val.ValidatePassword(req.GetPassword()); err != nil {
        violations = append(violations, fieldViolation("password", err))
    }
}

if req.FullName != nil {
    if err := val.ValidateFullName(req.GetFullName()); err != nil {
        violations = append(violations, fieldViolation("full_name", err))
    }
}

if req.Email != nil {
    if err := val.ValidateEmail(req.GetEmail()); err != nil {
        violations = append(violations, fieldViolation("email", err))
    }
}
```

这样客户端只改邮箱时，不需要同时传合法的姓名和密码。

接着把 protobuf request 转成 sqlc 参数：

```go
arg := db.UpdateUserParams{
    Username: req.GetUsername(),
    FullName: sql.NullString{
        String: req.GetFullName(),
        Valid:  req.FullName != nil,
    },
    Email: sql.NullString{
        String: req.GetEmail(),
        Valid:  req.Email != nil,
    },
}
```

密码比较特殊，不能直接保存明文。只有请求里带了 `password`，服务端才重新 hash，并更新 `password_changed_at`：

```go
if req.Password != nil {
    hashedPassword, err := util.HashPassword(req.GetPassword())
    if err != nil {
        return nil, status.Errorf(codes.Internal, "failed to hash password")
    }

    arg.HashedPassword = sql.NullString{
        String: hashedPassword,
        Valid:  true,
    }

    arg.PasswordChangedAt = sql.NullTime{
        Time:  time.Now(),
        Valid: true,
    }
}
```

最后调用 store 更新数据库：

```go
user, err := server.store.UpdateUser(ctx, arg)
if err != nil {
    if err == sql.ErrNoRows {
        return nil, status.Errorf(codes.NotFound, "user not found")
    }
    return nil, status.Errorf(codes.Internal, "failed to update user: %s", err)
}
```

错误仍然按 gRPC code 分层：

| 场景 | gRPC code |
| ---- | ---- |
| 参数格式错误 | `InvalidArgument` |
| 用户不存在 | `NotFound` |
| hash 密码失败或数据库错误 | `Internal` |

## 为什么还要加授权

到这里，`UpdateUser` 已经能工作，但还有一个严重问题：请求里带了 `username`，如果不校验调用者身份，任何拿到接口的人都可以尝试更新别人的资料。

所以需要给 gRPC API 加了授权逻辑。更新用户前必须提供 access token，而且 token 里的用户名必须和请求里的用户名一致。

gRPC 请求应该带上这样的 metadata：

```text
authorization: bearer <access_token>
```

HTTP Gateway 请求则可以使用同名 Header：

```text
Authorization: Bearer <access_token>
```

Gateway 会把 HTTP header 转进 gRPC metadata，最后仍然由同一个 gRPC handler 处理。

## 从 gRPC metadata 解析 Bearer token

新增 `gapi/authorization.go`，核心函数是 `authorizeUser`：

```go
func (server *Server) authorizeUser(ctx context.Context) (*token.Payload, error) {
    md, ok := metadata.FromIncomingContext(ctx)
    if !ok {
        return nil, fmt.Errorf("missing metadata")
    }

    values := md.Get(authorizationHeader)
    if len(values) == 0 {
        return nil, fmt.Errorf("missing authorization header")
    }

    authHeader := values[0]
    fields := strings.Fields(authHeader)
    if len(fields) < 2 {
        return nil, fmt.Errorf("invalid authorization header format")
    }

    authType := strings.ToLower(fields[0])
    if authType != authorizationBearer {
        return nil, fmt.Errorf("unsupported authorization type: %s", authType)
    }

    accessToken := fields[1]
    payload, err := server.tokenMaker.VerifyToken(accessToken)
    if err != nil {
        return nil, fmt.Errorf("invalid access token: %s", err)
    }

    return payload, nil
}
```

它做了几层检查：

| 检查 | 错误示例 |
| ---- | ---- |
| metadata 是否存在 | `missing metadata` |
| 是否有 authorization header | `missing authorization header` |
| header 格式是否正确 | `invalid authorization header format` |
| 授权类型是否为 bearer | `unsupported authorization type` |
| token 是否有效 | `invalid access token` |

这些错误最后会统一转成 `Unauthenticated`：

```go
func unauthenticatedError(err error) error {
    return status.Errorf(codes.Unauthenticated, "unauthorized: %s", err)
}
```

`Unauthenticated` 表示“你还没有证明自己是谁”，适合缺 token、token 格式错误、token 过期或签名不对这类情况。

## 防止用户更新别人的资料

通过 token 认证后，还需要做授权检查。

`UpdateUser` 一开始先解析 token：

```go
authPayload, err := server.authorizeUser(ctx)
if err != nil {
    return nil, unauthenticatedError(err)
}
```

然后比较 token payload 里的用户名和请求里的用户名：

```go
if authPayload.Username != req.GetUsername() {
    return nil, status.Errorf(codes.PermissionDenied, "cannot update other user's info")
}
```

这里区分两个错误：

| 场景 | gRPC code | 含义 |
| ---- | ---- | ---- |
| 没有有效 token | `Unauthenticated` | 还不知道你是谁 |
| token 有效，但要改别人资料 | `PermissionDenied` | 知道你是谁，但你没有权限 |

这两个 code 分开后，客户端也更容易处理。`Unauthenticated` 通常引导用户重新登录；`PermissionDenied` 则说明当前账号不能做这个操作。

## 当前的用户接口状态

现在 Simple Bank 的用户相关接口变成三类：

| 接口 | 是否需要登录 | 作用 |
| ---- | ---- | ---- |
| `CreateUser` | 否 | 注册新用户 |
| `LoginUser` | 否 | 登录并签发 access token / refresh token |
| `UpdateUser` | 是 | 更新当前用户的姓名、邮箱或密码 |

对应入口：

| RPC | HTTP |
| ---- | ---- |
| `CreateUser` | `POST /v1/create_user` |
| `LoginUser` | `POST /v1/login_user` |
| `UpdateUser` | `PATCH /v1/update_user` |


## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| `UpdateUser` SQL | 数据库支持按用户名更新用户资料 |
| `sqlc.narg` | 让更新参数变成 nullable，区分传值和不传值 |
| `COALESCE` | 未传字段保留原数据库值 |
| `UpdateUserParams` | 用 `sql.NullString` / `sql.NullTime` 表达可选更新字段 |
| 更新测试 | 验证单字段更新不会误改其他字段 |
| `mockgen` 接入 `make sqlc` | 重新生成 sqlc 后同步更新 mock store |
| `UpdateUserRequest` | 用 protobuf optional 字段表达局部更新 |
| `PATCH /v1/update_user` | 通过 Gateway 暴露用户更新 HTTP API |
| `validateUpdateUserRequest` | 只校验请求里实际传入的可选字段 |
| 密码重新 hash | 避免把明文密码写入数据库 |
| `password_changed_at` | 只在更新密码时刷新密码变更时间 |
| `authorizeUser` | 从 gRPC metadata 解析并校验 Bearer token |
| `Unauthenticated` | 统一处理缺 token 或 token 无效的请求 |
| `PermissionDenied` | 阻止已登录用户更新其他人的资料 |

到这里，Simple Bank 的 gRPC API 开始具备受保护接口的形态了。公开接口负责注册和登录，登录后拿到 access token，再用 Bearer token 调用 `UpdateUser`。数据库层、protobuf 层和 gRPC handler 都围绕“局部更新”和“只能更新自己”这两个约束收紧了一遍。
