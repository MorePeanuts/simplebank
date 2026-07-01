# 03. CRUD 代码的单元测试
## 补充 `entries` 和 `transfers` 表的查询语句

`accounts` 表的 SQL 已经在 [02. 生成 CRUD 代码](./02_generate_crud.md) 中写过，这里参照同样的写法，给另外两张表加上查询语句。

`db/query/entry.sql`：

```sql
-- name: CreateEntry :one
INSERT INTO entries (
  account_id,
  amount
) VALUES (
  $1, $2
) RETURNING *;

-- name: GetEntry :one
SELECT * FROM entries
WHERE id = $1 LIMIT 1;

-- name: ListEntries :many
SELECT * FROM entries
WHERE account_id = $1
ORDER BY id
LIMIT $2
OFFSET $3;
```

`db/query/transfer.sql`：

```sql
-- name: CreateTransfer :one
INSERT INTO transfers (
  from_account_id,
  to_account_id,
  amount
) VALUES (
  $1, $2, $3
) RETURNING *;

-- name: GetTransfer :one
SELECT * FROM transfers
WHERE id = $1 LIMIT 1;

-- name: ListTransfers :many
SELECT * FROM transfers
WHERE 
    from_account_id = $1 OR
    to_account_id = $2
ORDER BY id
LIMIT $3
OFFSET $4;
```

需要注意的几点：

- `entries` 表只属于某一个账户，所以 `ListEntries` 直接按 `account_id` 过滤。
- `transfers` 表既要查"从某个账户转出"的记录，也要查"转入到某个账户"的记录，所以 `ListTransfers` 用 `from_account_id = $1 OR to_account_id = $2` 来匹配两个方向。
- 没有为 `entries` 和 `transfers` 写 `Update` / `Delete`：业务上账本类记录是一旦写入就不可变更的（修改流水会破坏对账的可审计性），需要修正只能再追加一条反向记录。

写完之后执行：

```bash
make sqlc
```

`db/sqlc/` 目录下会多出 `entry.sql.go` 和 `transfer.sql.go`，包含 `CreateEntry`、`GetEntry`、`ListEntries`、`CreateTransfer`、`GetTransfer`、`ListTransfers` 这些函数，以及对应的参数结构体。

## 准备测试用的随机数据生成器

为了让单元测试不依赖固定输入、避免每次跑测试都要清库，新增一个 `util` 包用来生成随机的测试数据。

`util/random.go`：

```go
package util

import (
	"math/rand"
	"strings"
	"time"
)

const alphabet = "abcdefghijklmnopqrstuvwxyz"

func init() {
	rand.Seed(time.Now().UnixNano())
}

// RandomInt generates a random integer between min and max
func RandomInt(min, max int64) int64 {
	return min + rand.Int63n(max-min+1)
}

// RandomString generates a random string of length n
func RandomString(n int) string {
	var sb strings.Builder
	k := len(alphabet)

	for range n {
		c := alphabet[rand.Intn(k)]
		sb.WriteByte(c)
	}

	return sb.String()
}

// RandomOwner generates a random owner name
func RandomOwner() string {
	return RandomString(6)
}

// RandomMoney generates a random amount of money
func RandomMoney() int64 {
	return RandomInt(0, 1000)
}

// RandomCurrency generates a random currency code
func RandomCurrency() string {
	currencies := []string{"EUR", "USD", "CAD"}
	n := len(currencies)
	return currencies[rand.Intn(n)]
}
```

几个细节：

- `init()` 中用 `time.Now().UnixNano()` 给 `math/rand` 设置种子，避免每次运行得到完全相同的数据。
- `RandomOwner` 返回 6 位的小写字母字符串作为账户拥有者；`RandomMoney` 返回 0 ~ 1000 之间的整数作为金额；`RandomCurrency` 在 `EUR / USD / CAD` 中随机选择，对应业务里允许的货币种类。

## 配置测试入口 `TestMain`

Go 在跑某个包的测试时，如果该包内定义了 `TestMain` 函数，就会用它替代默认的入口；可以在里面做"建立连接、初始化全局资源"等准备工作，再调用 `m.Run()` 真正去跑各个 `TestXxx`。

`db/sqlc/main_test.go`：

```go
package db

import (
	"database/sql"
	"log"
	"os"
	"testing"

	_ "github.com/lib/pq"
)

const (
	dbDriver = "postgres"
	dbSource = "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable"
)

var testQueries *Queries

func TestMain(m *testing.M) {
	conn, err := sql.Open(dbDriver, dbSource)
	if err != nil {
		log.Fatal("cannot connect to db:", err)
	}

	testQueries = New(conn)

	os.Exit(m.Run())
}
```

- `_ "github.com/lib/pq"` 用空导入触发驱动的 `init()`，让 `database/sql` 知道 `"postgres"` 这个 driver 名字对应的实现。`sql.Open` 本身不会去校验连接是否真的可用，连接错误要等到第一次执行 SQL 时才会暴露。
- `dbSource` 直接写死了本地容器的连接串，和 `make migrateup` 用的是同一个；后续会在 [07. 配置管理](./07_config_management.md) 中改成从配置文件读取。
- `testQueries` 是一个包级变量，所有 `*_test.go` 共享它来发起 SQL 调用。

## 为 `accounts` 表编写单元测试

`db/sqlc/account_test.go`：

```go
package db

import (
	"context"
	"database/sql"
	"testing"
	"time"

	"github.com/MorePeanuts/simplebank/util"
	"github.com/stretchr/testify/require"
)

func createRandomAccount(t *testing.T) Account {
	arg := CreateAccountParams{
		Owner:    util.RandomOwner(),
		Balance:  util.RandomMoney(),
		Currency: util.RandomCurrency(),
	}

	account, err := testQueries.CreateAccount(context.Background(), arg)
	require.NoError(t, err)
	require.NotEmpty(t, account)

	require.Equal(t, arg.Owner, account.Owner)
	require.Equal(t, arg.Balance, account.Balance)
	require.Equal(t, arg.Currency, account.Currency)

	require.NotZero(t, account.ID)
	require.NotZero(t, account.CreatedAt)

	return account
}

func TestCreateAccount(t *testing.T) {
	createRandomAccount(t)
}

func TestGetAccount(t *testing.T) {
	account1 := createRandomAccount(t)
	account2, err := testQueries.GetAccount(context.Background(), account1.ID)
	require.NoError(t, err)
	require.NotEmpty(t, account2)

	require.Equal(t, account1.ID, account2.ID)
	require.Equal(t, account1.Owner, account2.Owner)
	require.Equal(t, account1.Balance, account2.Balance)
	require.Equal(t, account1.Currency, account2.Currency)
	require.WithinDuration(t, account1.CreatedAt, account2.CreatedAt, time.Second)
}

func TestUpdateAccount(t *testing.T) {
	account1 := createRandomAccount(t)

	arg := UpdateAccountParams{
		ID:      account1.ID,
		Balance: util.RandomMoney(),
	}

	account2, err := testQueries.UpdateAccount(context.Background(), arg)
	require.NoError(t, err)
	require.NotEmpty(t, account2)

	require.Equal(t, account1.ID, account2.ID)
	require.Equal(t, account1.Owner, account2.Owner)
	require.Equal(t, arg.Balance, account2.Balance)
	require.Equal(t, account1.Currency, account2.Currency)
	require.WithinDuration(t, account1.CreatedAt, account2.CreatedAt, time.Second)
}

func TestDeleteAccount(t *testing.T) {
	account1 := createRandomAccount(t)
	err := testQueries.DeleteAccount(context.Background(), account1.ID)
	require.NoError(t, err)

	account2, err := testQueries.GetAccount(context.Background(), account1.ID)
	require.Error(t, err)
	require.EqualError(t, err, sql.ErrNoRows.Error())
	require.Empty(t, account2)
}

func TestListAccounts(t *testing.T) {
	for range 10 {
		createRandomAccount(t)
	}

	arg := ListAccountsParams{
		Limit:  5,
		Offset: 5,
	}

	accounts, err := testQueries.ListAccounts(context.Background(), arg)
	require.NoError(t, err)
	require.Len(t, accounts, 5)

	for _, account := range accounts {
		require.NotEmpty(t, account)
	}
}
```

- `createRandomAccount` 是一个在测试内部复用的 helper：它本身完成 Create 的断言，并把创建出来的 `Account` 返回，后续 Get / Update / Delete / List 测试都通过它来构造前置数据。
- 用 [`testify/require`](https://github.com/stretchr/testify) 而不是标准库的 `t.Errorf`：`require.*` 在断言失败时会立刻 `t.FailNow()` 终止当前测试，避免后续步骤在错误前提下继续执行干扰排查。
- `require.WithinDuration` 用来比较两个 `time.Time`，允许 1 秒之内的偏差。直接用 `Equal` 比较时间戳常常会因为 Postgres 端存储精度（`timestamptz` 默认到微秒）和 Go 端 `time.Time` 的精度差异而失败。
- `TestDeleteAccount` 在删除之后再 `GetAccount` 一次，期望拿到 `sql.ErrNoRows` —— 这是 `database/sql` 在 `QueryRow().Scan()` 没匹配到行时的标准错误。
- `TestListAccounts` 先连续创建 10 个账户，再用 `Limit=5, Offset=5` 取第二页，期望恰好返回 5 条记录。这里没有去断言"返回的是哪 5 个账户"，因为多次跑测试会在表里留下越来越多的历史数据，断言具体内容会让测试不稳定。

## 为 `entries` 表编写单元测试

`db/sqlc/entry_test.go`：

```go
package db

import (
	"context"
	"testing"
	"time"

	"github.com/MorePeanuts/simplebank/util"
	"github.com/stretchr/testify/require"
)

func createRandomEntry(t *testing.T, account Account) Entry {
	arg := CreateEntryParams{
		AccountID: account.ID,
		Amount:    util.RandomMoney(),
	}

	entry, err := testQueries.CreateEntry(context.Background(), arg)
	require.NoError(t, err)
	require.NotEmpty(t, entry)

	require.Equal(t, arg.AccountID, entry.AccountID)
	require.Equal(t, arg.Amount, entry.Amount)

	require.NotZero(t, entry.ID)
	require.NotZero(t, entry.CreatedAt)

	return entry
}

func TestCreateEntry(t *testing.T) {
	account := createRandomAccount(t)
	createRandomEntry(t, account)
}

func TestGetEntry(t *testing.T) {
	account := createRandomAccount(t)
	entry1 := createRandomEntry(t, account)
	entry2, err := testQueries.GetEntry(context.Background(), entry1.ID)
	require.NoError(t, err)
	require.NotEmpty(t, entry2)

	require.Equal(t, entry1.ID, entry2.ID)
	require.Equal(t, entry1.AccountID, entry2.AccountID)
	require.Equal(t, entry1.Amount, entry2.Amount)
	require.WithinDuration(t, entry1.CreatedAt, entry2.CreatedAt, time.Second)
}

func TestListEntries(t *testing.T) {
	account := createRandomAccount(t)
	for i := 0; i < 10; i++ {
		createRandomEntry(t, account)
	}

	arg := ListEntriesParams{
		AccountID: account.ID,
		Limit:     5,
		Offset:    5,
	}

	entries, err := testQueries.ListEntries(context.Background(), arg)
	require.NoError(t, err)
	require.Len(t, entries, 5)

	for _, entry := range entries {
		require.NotEmpty(t, entry)
		require.Equal(t, arg.AccountID, entry.AccountID)
	}
}
```

要点：

- `entries` 表通过 `account_id` 外键依赖 `accounts`，所以 `createRandomEntry` 必须先调用 `createRandomAccount` 拿到一个有效的账户 ID，否则插入会因外键约束失败。
- `TestListEntries` 创建 10 个属于同一个新账户的 entry，再分页取出 5 条。因为是新账户，可以放心地断言 "返回的所有 entry 的 `AccountID` 都等于这个账户"。

## 为 `transfers` 表编写单元测试

`db/sqlc/transfer_test.go`：

```go
package db

import (
	"context"
	"testing"
	"time"

	"github.com/MorePeanuts/simplebank/util"
	"github.com/stretchr/testify/require"
)

func createRandomTransfer(t *testing.T, account1, account2 Account) Transfer {
	arg := CreateTransferParams{
		FromAccountID: account1.ID,
		ToAccountID:   account2.ID,
		Amount:        util.RandomMoney(),
	}

	transfer, err := testQueries.CreateTransfer(context.Background(), arg)
	require.NoError(t, err)
	require.NotEmpty(t, transfer)

	require.Equal(t, arg.FromAccountID, transfer.FromAccountID)
	require.Equal(t, arg.ToAccountID, transfer.ToAccountID)
	require.Equal(t, arg.Amount, transfer.Amount)

	require.NotZero(t, transfer.ID)
	require.NotZero(t, transfer.CreatedAt)

	return transfer
}

func TestCreateTransfer(t *testing.T) {
	account1 := createRandomAccount(t)
	account2 := createRandomAccount(t)
	createRandomTransfer(t, account1, account2)
}

func TestGetTransfer(t *testing.T) {
	account1 := createRandomAccount(t)
	account2 := createRandomAccount(t)
	transfer1 := createRandomTransfer(t, account1, account2)

	transfer2, err := testQueries.GetTransfer(context.Background(), transfer1.ID)
	require.NoError(t, err)
	require.NotEmpty(t, transfer2)

	require.Equal(t, transfer1.ID, transfer2.ID)
	require.Equal(t, transfer1.FromAccountID, transfer2.FromAccountID)
	require.Equal(t, transfer1.ToAccountID, transfer2.ToAccountID)
	require.Equal(t, transfer1.Amount, transfer2.Amount)
	require.WithinDuration(t, transfer1.CreatedAt, transfer2.CreatedAt, time.Second)
}

func TestListTransfer(t *testing.T) {
	account1 := createRandomAccount(t)
	account2 := createRandomAccount(t)

	for i := 0; i < 5; i++ {
		createRandomTransfer(t, account1, account2)
		createRandomTransfer(t, account2, account1)
	}

	arg := ListTransfersParams{
		FromAccountID: account1.ID,
		ToAccountID:   account1.ID,
		Limit:         5,
		Offset:        5,
	}

	transfers, err := testQueries.ListTransfers(context.Background(), arg)
	require.NoError(t, err)
	require.Len(t, transfers, 5)

	for _, transfer := range transfers {
		require.NotEmpty(t, transfer)
		require.True(t, transfer.FromAccountID == account1.ID || transfer.ToAccountID == account1.ID)
	}
}
```

要点：

- 转账涉及两个账户，所以 `createRandomTransfer` 接收两个 `Account` 作为参数。
- `TestListTransfer` 在两个新账户之间双向各转 5 次，一共 10 条记录。`ListTransfers` 的 SQL 是 `from_account_id = $1 OR to_account_id = $2`，所以这里把 `FromAccountID` 和 `ToAccountID` 都填成 `account1.ID`，等价于"列出所有 account1 参与的 transfer"，应该正好能取到 10 条；分页 `Limit=5, Offset=5` 拿到第二页 5 条。
- 循环里对每条记录断言 `FromAccountID == account1.ID || ToAccountID == account1.ID`，确保 SQL 的 `OR` 条件确实生效。

## 在 Makefile 中加入 `test` 目标

为了能用一条命令跑全部测试，给 `Makefile` 加一个 `test` 目标：

```makefile
test:
	go test -v -cover ./...

.PHONY: postgres createdb dropdb migrateup migratedown sqlc test
```

参数说明：

- `-v`：打印每个 test case 的执行情况，方便看到具体哪个用例跑过了/失败了。
- `-cover`：输出每个包的覆盖率统计；后续如果想要更细粒度的覆盖率报告，可以再加 `-coverprofile=...` 输出覆盖率文件。
- `./...`：递归跑当前模块下所有包的测试。

跑测试前需要确认本地 PostgreSQL 容器已经启动并完成迁移：

```bash
make postgres
make createdb
make migrateup
make test
```
