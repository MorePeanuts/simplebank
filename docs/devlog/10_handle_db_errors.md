# 10. 处理数据库错误

目前的代码中，`createAccount` 在数据库层面违反约束的时候，handler 一律返回 500。这意味着客户端拿到一个"服务器内部错误"，根本没法区分——**到底是后端真的挂了，还是自己传了一个不合法的参数？**

这一节分两步进行处理：

1. **加 `users` 表**：把"账户必须挂在某个真实用户名下"和"同一个用户在同一种货币下只能有一个账户"两条规则用约束写进 schema；
2. **识别 `pq.Error`**：在 `createAccount` 里把 PostgreSQL 抛出来的具体错误码翻译成对应的 HTTP 状态码，让 4xx 和 5xx 各归各的。

## 加一张 `users` 表

新建 migration 文件 `db/migration/000002_add_users.up.sql`：

```sql
CREATE TABLE "users" (
  "username" varchar PRIMARY KEY,
  "hashed_password" varchar NOT NULL,
  "full_name" varchar NOT NULL,
  "email" varchar UNIQUE NOT NULL,
  "password_changed_at" timestamptz NOT NULL DEFAULT '0001-01-01 00:00:00Z',
  "created_at" timestamptz NOT NULL DEFAULT (now())
);

ALTER TABLE "accounts" ADD FOREIGN KEY ("owner") REFERENCES "users" ("username") DEFERRABLE INITIALLY IMMEDIATE;

-- CREATE UNIQUE INDEX ON "accounts" ("owner", "currency");
ALTER TABLE "accounts" ADD CONSTRAINT "owner_currency_key" UNIQUE ("owner", "currency");
```

- **`username` 直接当主键**：用户名本身天然唯一，没必要再单独引入一个自增 `id`；后面 `accounts.owner` 直接引用它。
- **`email UNIQUE NOT NULL`**：邮箱在业务上要求唯一，约束写在数据库层比写在应用层靠谱得多。
- **`password_changed_at` 默认 `'0001-01-01 00:00:00Z'`**：用 Go `time.Time` 的零值作为"还没改过密码"的哨兵值，免去了搞一个 `*time.Time` 来表达"可空"。后续 [11. 密码存储](./11_store_password.md) 会真正改这个字段。
- **外键 `accounts.owner → users.username`：新建账户时如果 `owner` 在 `users` 里查不到，直接由数据库拒绝**。
- **`(owner, currency)` 复合唯一约束**：业务规则是"一个用户在每种币种下最多开一个账户"。这里被注释掉的 `CREATE UNIQUE INDEX` 和 `ADD CONSTRAINT ... UNIQUE` 在 PostgreSQL 里实现上几乎等价（约束底层也是用唯一索引来实现的），但**约束有名字、`information_schema` 里能查到**，错误信息也更友好。后面识别 `pq.Error` 时，违反约束抛出的就是 `unique_violation`，正好能用。
- **`DEFERRABLE INITIALLY IMMEDIATE`**：和 [01. 数据库设计](./01_database_design.md) 里其他外键保持一致，默认每条语句结束时检查，但保留事务里 `SET CONSTRAINTS ALL DEFERRED` 的可能性。

对应的 down migration `db/migration/000002_add_users.down.sql`：

```sql
ALTER TABLE IF EXISTS "accounts" DROP CONSTRAINT IF EXISTS "owner_currency_key";

ALTER TABLE IF EXISTS "accounts" DROP CONSTRAINT IF EXISTS "accounts_owner_fkey";

DROP TABLE IF EXISTS "users";
```

down 的顺序和 up 完全反过来：先把 `accounts` 上指向 `users` 的两条约束摘掉，最后再 `DROP TABLE users`。`accounts_owner_fkey` 这个名字是 PostgreSQL 在 `ADD FOREIGN KEY` 没显式命名时自动生成的。

### `migrateup1` / `migratedown1`

给 `Makefile` 里加上"只跑一步"的快捷指令：

```makefile
migrateup1:
	migrate -path db/migration -database "..." -verbose up 1

migratedown1:
	migrate -path db/migration -database "..." -verbose down 1
```

`up 1` / `down 1` 是 `golang-migrate` 自带的参数，意思是"在当前版本基础上前进/回退 1 步"。

```makefile
.PHONY: postgres createdb dropdb migrateup migrateup1 migratedown migratedown1 sqlc test server mock
```

## 让 `sqlc` 生成 `User` 的 CRUD

新建 `db/query/user.sql`：

```sql
-- name: CreateUser :one
INSERT INTO users (
  username,
  hashed_password,
  full_name,
  email
) VALUES (
  $1, $2, $3, $4
)
RETURNING *;

-- name: GetUser :one
SELECT * FROM users
WHERE username = $1 LIMIT 1;
```

`make sqlc` 之后会在 `db/sqlc/user.sql.go` 里多出 `CreateUser`、`GetUser` 两个方法，以及 `db/sqlc/models.go` 里的 `User` 结构体。同时 `Querier` 接口也会自动加上这两个方法。

**`db/mock/store.go` 里的 `MockStore` 必须重新生成**，否则它实现的还是旧版 `Store` 接口，编译过不去。`make mock` 跑一遍即可。

## 给 `users` 表写 CRUD 测试

测试里 `HashedPassword` 直接塞了一个 `"secret"` 字面量——这一节关心的是"表结构和 CRUD 通不通"，不是"密码该怎么存"。哈希、强度、`password_changed_at` 的真正写入都留到 [11. 密码存储](./11_store_password.md) 再处理；这里只要求这个字段是 `NOT NULL` 的字符串，能写进去、读出来一致就行。

`db/sqlc/user_test.go`：

```go
func createRandomUser(t *testing.T) User {
    arg := CreateUserParams{
        Username:       util.RandomOwner(),
        HashedPassword: "secret",
        FullName:       util.RandomOwner(),
        Email:          util.RandomEmail(),
    }

    user, err := testQueries.CreateUser(context.Background(), arg)
    require.NoError(t, err)
    require.NotEmpty(t, user)

    require.Equal(t, arg.Username, user.Username)
    require.Equal(t, arg.HashedPassword, user.HashedPassword)
    require.Equal(t, arg.FullName, user.FullName)
    require.Equal(t, arg.Email, user.Email)

    require.True(t, user.PasswordChangedAt.IsZero())
    require.NotZero(t, user.CreatedAt)

    return user
}

func TestCreateUser(t *testing.T) {
    createRandomUser(t)
}

func TestGetUser(t *testing.T) {
    user1 := createRandomUser(t)
    user2, err := testQueries.GetUser(context.Background(), user1.Username)
    require.NoError(t, err)
    require.NotEmpty(t, user2)

    require.Equal(t, user1.Username, user2.Username)
    require.Equal(t, user1.HashedPassword, user2.HashedPassword)
    require.Equal(t, user1.FullName, user2.FullName)
    require.Equal(t, user1.Email, user2.Email)
    require.WithinDuration(t, user1.PasswordChangedAt, user2.PasswordChangedAt, time.Second)
    require.WithinDuration(t, user1.CreatedAt, user2.CreatedAt, time.Second)
}
```

两个细节延续 [03. CRUD 单元测试](./03_unit_test_for_crud.md) 里的写法：

- `require.True(t, user.PasswordChangedAt.IsZero())`：明确断言"刚创建的用户密码没改过"。如果哪天 schema 把默认值改没了，这条断言会立刻失败。
- `require.WithinDuration(...)`：时间字段不要用 `Equal` 比，往返数据库时 `timestamptz` 的精度可能导致纳秒位丢失，给 1 秒的容差就够。

`util/random.go` 顺手补一个 `RandomEmail`：

```go
// RandomEmail generates a random email
func RandomEmail() string {
    return fmt.Sprintf("%s@email.com", RandomString(6))
}
```

### `account_test.go` 顺势打补丁

外键加上之后，`createRandomAccount` 里那行 `Owner: util.RandomOwner()` 就跑不通了——随机字符串不可能命中 `users` 表里的某一行，`INSERT` 会被外键约束拒掉。改法是先建一个用户、再用它的 `username` 去建账户：

```go
func createRandomAccount(t *testing.T) Account {
    user := createRandomUser(t)

    arg := CreateAccountParams{
        Owner:    user.Username,
        Balance:  util.RandomMoney(),
        Currency: util.RandomCurrency(),
    }
    // ...
}
```

这一改不只是为了"让测试通过"，更是把"账户必须挂在某个真实用户名下"这条业务规则在测试里也表达了一遍。

## 把 `pq.Error` 翻成对应状态码

回到一开始的问题：`createAccount` 在外键、唯一键违反时该怎么响应。

打开 `api/account.go`：

```go
import (
    // ...
    "github.com/lib/pq"
)

func (server *Server) createAccount(ctx *gin.Context) {
    // ... 解析 req、构造 arg ...

    account, err := server.store.CreateAccount(ctx, arg)
    if err != nil {
        if pqErr, ok := err.(*pq.Error); ok {
            switch pqErr.Code.Name() {
            case "foreign_key_violation", "unique_violation":
                ctx.JSON(http.StatusForbidden, errorResponse(err))
                return
            }
        }
        ctx.JSON(http.StatusInternalServerError, errorResponse(err))
        return
    }

    ctx.JSON(http.StatusOK, account)
}
```

逐项展开：

### `*pq.Error` 是什么

项目用的 PostgreSQL 驱动是 [`github.com/lib/pq`](https://github.com/lib/pq)。当数据库返回一个 SQL 错误（不管是约束违反、表不存在、还是语法错误），驱动会把它包装成一个 `*pq.Error`：

```go
type Error struct {
    Severity string
    Code     ErrorCode  // PostgreSQL SQLSTATE code, 5 个字符
    Message  string
    Detail   string
    Hint     string
    // ...
}
```

`Code` 是 PostgreSQL 的 [SQLSTATE](https://www.postgresql.org/docs/current/errcodes-appendix.html)，五位字符串。`pq` 还提供了 `Code.Name()` 把它翻成可读名字——`"23503"` → `"foreign_key_violation"`，`"23505"` → `"unique_violation"`。

### 为什么是类型断言而不是 `errors.As`

更"现代"的写法应该是：

```go
var pqErr *pq.Error
if errors.As(err, &pqErr) {
    // ...
}
```

这一节先用类型断言保持简单。`store.CreateAccount` 内部并没有用 `fmt.Errorf("%w", err)` 把驱动错误再包一层，所以 `err` 直接就是 `*pq.Error`，类型断言够用。如果有中间层去 wrap 错误的时候，需要换成 `errors.As` 。

### 为什么是 `403` 不是 `400` / `409`

外键和唯一键违反这两类错误，HTTP 上其实有更精确的对应：

- 外键违反"对方不存在" → `404 Not Found`
- 唯一键违反"重复创建" → `409 Conflict`

这一节先一刀切返回 `403 Forbidden`，把"问题在客户端这边、不是服务器挂了"这件事说清楚，**优先把 5xx 的范围收窄**。

## 验证一下

跑测试和打实际请求各走一遍。

```bash
make migrateup
make sqlc
make mock
make test
```

测试这一步会把上面新加的 `TestCreateUser` / `TestGetUser` 跑起来，同时 `account_test.go` 因为现在依赖 `createRandomUser`，每个 case 都会先去 `users` 表里插一条记录——外键和这条修复的协同就在这里被验证。

接着用 Bruno 打一次 `Create Account`：

| 场景 | Body | 预期 |
| ---- | ---- | ---- |
| 正常 | `{"owner": "alice", "currency": "USD"}`（`alice` 已在 `users` 表中） | `200`，返回 `Account` |
| 外键违反 | `{"owner": "ghost", "currency": "USD"}`（`ghost` 不存在） | `403`，错误信息含 `violates foreign key constraint "accounts_owner_fkey"` |
| 唯一键违反 | 重复用上一条同 owner / currency 再发一次 | `403`，错误信息含 `violates unique constraint "owner_currency_key"` |
| 真实 5xx | 把数据库容器停掉再发请求 | `500`，错误信息是连接错误 |

这四条对应四条不同的代码路径：第一条不进 `if pqErr, ok`；第二条命中 `foreign_key_violation`；第三条命中 `unique_violation`；第四条 `err` 不是 `*pq.Error`（多半是 `*net.OpError`），类型断言失败，直接落到外层 500。

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| 新增 `users` 表 + `accounts.owner` 外键 + `(owner, currency)` 唯一约束 | 把"账户必须挂在真实用户名下"和"一个用户每种币种只能有一个账户"两条规则下沉到数据库 |
| `Makefile` 新增 `migrateup1` / `migratedown1` | 调试 down migration 时只前进/回退一步 |
| `db/query/user.sql` + `make sqlc` 生成 `CreateUser` / `GetUser` | 让 `users` 表也走 sqlc 生成的类型安全 API |
| `make mock` 重新生成 `MockStore` | 接口加了 `CreateUser` / `GetUser`，mock 必须同步 |
| `db/sqlc/user_test.go` + `account_test.go` 改 owner 来源 | 验证新表 CRUD，同时让账户测试满足新加的外键 |
| `util.RandomEmail` | 测试用例需要的随机邮箱 |
| `createAccount` 里识别 `*pq.Error.Code.Name()` | 把 `foreign_key_violation` / `unique_violation` 翻成 `403`，缩小 `500` 的范围 |

走完这一节之后，`createAccount` 的 4xx / 5xx 边界就清楚了：客户端拿到 4xx 就知道是自己传的参数有问题，拿到 5xx 才需要去 oncall 看后端。

下一节 [11. 密码存储](./11_store_password.md) 会真正用上 `users` 表——加 `createUser` handler，把密码用 bcrypt 哈希后写进去。
