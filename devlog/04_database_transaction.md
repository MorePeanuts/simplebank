# 04. 数据库事务和死锁问题
## 为什么需要数据库事务

[02. 生成 CRUD 代码](./02_generate_crud.md) 给三张表都生成了基础的 CRUD 函数，但银行的核心场景"从一个账户转钱到另一个账户"并不是一条 SQL 能搞定的事，最少要做 5 件事：

1. 在 `transfers` 表中插入一条转账记录；
2. 在 `entries` 表中插入一条 from 账户的负向流水（`-amount`）；
3. 在 `entries` 表中插入一条 to 账户的正向流水（`+amount`）；
4. 把 from 账户的 `balance` 减掉 `amount`；
5. 把 to 账户的 `balance` 加上 `amount`。

这 5 步必须满足 ACID：要么全部成功，要么全部不发生。否则一旦中间某一步失败（甚至程序崩了），就会出现"transfer 记录写下来了但余额没扣"、"扣了 from 账户的钱但 to 账户没加到钱"这种对账永远对不上的状态。所以这一节的目标，就是把上面 5 个查询封装到一个数据库事务里去执行。

## 添加 `Store` 抽象

由 `sqlc` 生成的 `Queries` 类型只能执行单条 SQL，无法跨多条 SQL 共享同一个连接 / 事务。需要在它之上再包一层 `Store`，让它既能执行单条 SQL，又能开启事务、把多条 SQL 串成一个原子单位。

`db/sqlc/store.go`：

```go
package db

import (
	"context"
	"database/sql"
	"fmt"
)

// Store provides all functions to execute db queries and transactions
type Store struct {
	*Queries
	db *sql.DB
}

// NewStore creates a new Store
func NewStore(db *sql.DB) *Store {
	return &Store{
		db:      db,
		Queries: New(db),
	}
}
```

几个关键设计：

- `Store` 用 **组合（composition）+ embedding** 的方式持有 `*Queries`：所有 `sqlc` 已经生成好的方法（`CreateAccount`、`GetAccount`、`CreateTransfer`、…）在 `Store` 上都直接可用，不需要重新写一遍委托函数。
- 同时还存了一份原始的 `*sql.DB`：因为开启事务（`BeginTx`）需要的是 `*sql.DB`，而不是 `*Queries`。`Queries` 只是对一个抽象的"查询执行器"的封装。
- `New(db)` 是 `sqlc` 生成的构造函数，签名是 `New(db DBTX) *Queries`，它接收的 `DBTX` 是一个接口（具备 `ExecContext / QueryContext / QueryRowContext`）。`*sql.DB` 和 `*sql.Tx` 都实现了这个接口 —— 这是后面实现事务的关键。

## 用闭包封装事务流程

`database/sql` 暴露的事务原语是一组散装的 `BeginTx / Commit / Rollback` 调用，每个事务方法都要重复写一段"开事务 → 跑 SQL → 出错回滚 → 没错提交"的样板，很容易漏掉某个 `Rollback`。统一抽出一个 `execTx` 工具方法：

```go
// execTx executes a function within a database transaction
func (store *Store) execTx(ctx context.Context, fn func(*Queries) error) error {
	tx, err := store.db.BeginTx(ctx, nil)
	if err != nil {
		return err
	}

	q := New(tx)
	err = fn(q)
	if err != nil {
		if rbErr := tx.Rollback(); rbErr != nil {
			return fmt.Errorf("tx error: %v, rb error: %v", err, rbErr)
		}
		return err
	}

	return tx.Commit()
}
```

要点：

- `BeginTx(ctx, nil)` 第二个参数是 `*sql.TxOptions`，可以指定隔离级别和只读属性，传 `nil` 表示用默认（PostgreSQL 默认是 `Read Committed`）。
- 关键的一行：`q := New(tx)`。把 `*sql.Tx` 传给 `New`，得到一个新的 `*Queries`，它内部所有 SQL 都跑在这个 `tx` 上。这就把"`sqlc` 生成的、各自看上去是独立连接的查询函数"绑定到了同一个事务里。
- `fn func(*Queries) error` 是回调：调用方负责往里面塞业务 SQL 序列。`execTx` 只关心"成功 ⇒ Commit / 失败 ⇒ Rollback"。
- `Rollback` 自身可能再失败（比如连接已经断了），所以包了一层 `fmt.Errorf` 把两个错误串起来上报，避免吞掉原始 error。
- `execTx` 是小写开头，包外不可见 —— 故意如此：业务代码不应该自己拼事务，而是通过 `Store` 暴露的具体业务方法（比如下面的 `TransferTx`）来开事务。

## 实现转账事务 `TransferTx`

```go
// TransferTxParams contains the input parameters of the transfer transaction
type TransferTxParams struct {
	FromAccountID int64 `json:"from_account_id"`
	ToAccountID   int64 `json:"to_account_id"`
	Amount        int64 `json:"amount"`
}

// TransferTxResult is the result of the transfer transaction
type TransferTxResult struct {
	Transfer    Transfer `json:"transfer"`
	FromAccount Account  `json:"from_account"`
	ToAccount   Account  `json:"to_account"`
	FromEntry   Entry    `json:"from_entry"`
	ToEntry     Entry    `json:"to_entry"`
}

// TransferTx performs a money transfer from one account to the other.
// It creates the transfer, add account entries, and update accounts' balance within a database transaction
func (store *Store) TransferTx(ctx context.Context, arg TransferTxParams) (TransferTxResult, error) {
	var result TransferTxResult

	err := store.execTx(ctx, func(q *Queries) error {
		var err error

		result.Transfer, err = q.CreateTransfer(ctx, CreateTransferParams(arg))
		if err != nil {
			return err
		}

		result.FromEntry, err = q.CreateEntry(ctx, CreateEntryParams{
			AccountID: arg.FromAccountID,
			Amount:    -arg.Amount,
		})
		if err != nil {
			return err
		}

		result.ToEntry, err = q.CreateEntry(ctx, CreateEntryParams{
			AccountID: arg.ToAccountID,
			Amount:    arg.Amount,
		})
		if err != nil {
			return err
		}

		// TODO: update accounts' balance

		return nil
	})

	return result, err
}
```

第一版只先把 transfer 和两条 entry 写下来，账户余额的更新留作 TODO —— 之所以分两步，是为了在加上余额更新之前先把测试跑通，再观察并发场景下可能遇到的问题。

注意几个细节：

- `TransferTxParams` 的字段刚好对应 `CreateTransferParams` 的 3 个字段，所以这里直接做了类型转换 `CreateTransferParams(arg)`，没必要再手写一遍 `CreateTransferParams{...}`。这是 Go 的"具有相同底层结构体可以互相转换"的语法。
- 闭包内每一步都要 `if err != nil { return err }`，事务一旦失败立刻 short-circuit，由 `execTx` 触发回滚。

## 配置事务测试入口

要并发跑事务测试，`*sql.DB` 必须在多个测试之间共享（`Queries` 持有的也是同一个连接池）。所以把 `db/sqlc/main_test.go` 改成额外暴露 `testDB`：

```go
var (
	testQueries *Queries
	testDB      *sql.DB
)

func TestMain(m *testing.M) {
	var err error

	testDB, err = sql.Open(dbDriver, dbSource)
	if err != nil {
		log.Fatal("cannot connect to db:", err)
	}

	testQueries = New(testDB)

	os.Exit(m.Run())
}
```

`testDB` 用来在事务测试里 `NewStore(testDB)` —— `Store` 必须拿到原始 `*sql.DB` 才能 `BeginTx`。

## 事务的单元测试

`db/sqlc/store_test.go`：

```go
func TestTransferTx(t *testing.T) {
	store := NewStore(testDB)

	account1 := createRandomAccount(t)
	account2 := createRandomAccount(t)

	// run a concurrent transfer transactions
	n := 5
	amount := int64(10)

	errs := make(chan error)
	results := make(chan TransferTxResult)

	for range n {
		go func() {
			result, err := store.TransferTx(context.Background(), TransferTxParams{
				FromAccountID: account1.ID,
				ToAccountID:   account2.ID,
				Amount:        amount,
			})

			errs <- err
			results <- result
		}()
	}

	// check results
	for range n {
		err := <-errs
		require.NoError(t, err)

		result := <-results
		require.NotEmpty(t, result)

		// check transfer
		transfer := result.Transfer
		require.Equal(t, account1.ID, transfer.FromAccountID)
		require.Equal(t, account2.ID, transfer.ToAccountID)
		require.Equal(t, amount, transfer.Amount)
		require.NotZero(t, transfer.ID)
		require.NotZero(t, transfer.CreatedAt)

		_, err = store.GetTransfer(context.Background(), transfer.ID)
		require.NoError(t, err)

		// check entries
		fromEntry := result.FromEntry
		require.NotEmpty(t, fromEntry)
		require.Equal(t, account1.ID, fromEntry.AccountID)
		require.Equal(t, -amount, fromEntry.Amount)
		require.NotZero(t, fromEntry.ID)
		require.NotZero(t, fromEntry.CreatedAt)

		_, err = store.GetEntry(context.Background(), fromEntry.ID)
		require.NoError(t, err)

		toEntry := result.ToEntry
		require.NotEmpty(t, toEntry)
		require.Equal(t, account2.ID, toEntry.AccountID)
		require.Equal(t, amount, toEntry.Amount)
		require.NotZero(t, toEntry.ID)
		require.NotZero(t, toEntry.CreatedAt)

		_, err = store.GetEntry(context.Background(), toEntry.ID)
		require.NoError(t, err)

		// check accounts' balance
	}
}
```

这个测试的设计思路：

- **并发**：用 `go` 启动 `n=5` 个 goroutine 同时跑 `TransferTx`。如果只跑一个事务，是无法发现锁、隔离级别、死锁这些问题的 —— 这些问题只在并发下才会暴露。
- **不能在 goroutine 里直接 `require.NoError(t, err)`**：`testify` 的 `require.*` 在失败时会调 `t.FailNow()`，而 `t.FailNow()` 必须在跑 test 的那个 goroutine 里调用，否则行为未定义。所以这里把 `err` 和 `result` 通过 channel 送回主 goroutine，再统一断言。
- **断言分三组**：transfer 记录 / from-entry / to-entry。每组都从 channel 取出后，再用 `GetTransfer / GetEntry` 把它从数据库再读一次确认确实落地了。

## 给账户余额更新加上 `FOR UPDATE` 锁

接下来在事务内补上"扣 from 账户余额 / 加 to 账户余额"的逻辑。最直觉的做法是：先 `SELECT` 账户拿到当前余额，然后 `UPDATE` 写回。

但是在并发场景下这是错的：

```
事务 A: SELECT balance from accounts WHERE id=1;  -- 读到 balance=100
事务 B: SELECT balance from accounts WHERE id=1;  -- 也读到 balance=100
事务 A: UPDATE accounts SET balance=90 WHERE id=1; -- A 算的: 100-10=90
事务 B: UPDATE accounts SET balance=90 WHERE id=1; -- B 算的: 100-10=90
```

两个事务都扣了 10，但账户余额只少了 10 —— 这就是经典的 **lost update**。Postgres 默认是 `Read Committed` 隔离级别，是允许这种交错的。

解决思路是查询时对行加锁，让别的事务等到这个事务结束才能读这一行的余额：

`db/query/account.sql`：

```sql
-- name: GetAccountForUpdate :one
SELECT * FROM accounts
WHERE id = $1 LIMIT 1
FOR UPDATE;
```

`FOR UPDATE` 是 SELECT 的修饰子句，表示在读到的行上加一个排他行锁，直到事务结束才释放。重新跑 `make sqlc` 生成对应的 `GetAccountForUpdate`。然后把 `TransferTx` 的 TODO 替换成：

```go
// get account -> update its balance
account1, err := q.GetAccountForUpdate(ctx, arg.FromAccountID)
if err != nil {
	return err
}

result.FromAccount, err = q.UpdateAccount(ctx, UpdateAccountParams{
	ID:      arg.FromAccountID,
	Balance: account1.Balance - arg.Amount,
})
if err != nil {
	return err
}

account2, err := q.GetAccountForUpdate(ctx, arg.ToAccountID)
if err != nil {
	return err
}

result.ToAccount, err = q.UpdateAccount(ctx, UpdateAccountParams{
	ID:      arg.ToAccountID,
	Balance: account2.Balance + arg.Amount,
})
if err != nil {
	return err
}
```

同时在 `store_test.go` 里把账户余额变化也校验上：

```go
// check accounts
fromAccount := result.FromAccount
require.NotEmpty(t, fromAccount)
require.Equal(t, account1.ID, fromAccount.ID)

toAccount := result.ToAccount
require.NotEmpty(t, toAccount)
require.Equal(t, account2.ID, toAccount.ID)

// check accounts' balance
fmt.Println(">> tx:", fromAccount.Balance, toAccount.Balance)
diff1 := account1.Balance - fromAccount.Balance
diff2 := toAccount.Balance - account2.Balance
require.Equal(t, diff1, diff2)
require.True(t, diff1 > 0)
require.True(t, diff1%amount == 0) // 1 * amount, 2 * amount, ..., n * amount

k := int(diff1 / amount)
require.True(t, k >= 1 && k <= n)
require.NotContains(t, existed, k)
existed[k] = true
```

校验思路：n 个事务并发跑，每个事务从 account1 转走 amount。如果完全串行化执行，那么对 account1 来说，看到的余额变化应该是 `-amount, -2*amount, …, -n*amount` 这样的序列；每个 k 必须出现一次且只出现一次。`existed` 用来跟踪已经看到的 k。

最后再读出 account 的最终状态对比：

```go
updateAccount1, err := testQueries.GetAccount(context.Background(), account1.ID)
require.NoError(t, err)

updateAccount2, err := testQueries.GetAccount(context.Background(), account2.ID)
require.NoError(t, err)

fmt.Println(">> after:", updateAccount1.Balance, updateAccount2.Balance)
require.Equal(t, account1.Balance-int64(n)*amount, updateAccount1.Balance)
require.Equal(t, account2.Balance+int64(n)*amount, updateAccount2.Balance)
```

## 第一次死锁：`FOR UPDATE` 暴露的外键依赖

跑 `make test` 之后，事务测试有概率挂掉，错误大致是：

```
ERROR: deadlock detected (SQLSTATE 40P01)
```

为了知道每个事务正卡在哪一条 SQL，给事务里每条查询前加一条 `fmt.Println` 打印当前事务名（通过 `context.WithValue` 传入的 `txKey`，对应 commit `e7a594d`）：

```go
var txKey = struct{}{}

// 在闭包里
txName := ctx.Value(txKey)
fmt.Println(txName, "create transfer")
// ...
fmt.Println(txName, "create fromEntry")
// ...
fmt.Println(txName, "get account1")
// ...
```

测试里给每个 goroutine 也起个名字塞进 ctx：

```go
for i := 0; i < n; i++ {
	txName := fmt.Sprintf("tx %d", i+1)
	go func() {
		ctx := context.WithValue(context.Background(), txKey, txName)
		result, err := store.TransferTx(ctx, TransferTxParams{...})
		// ...
	}()
}
```

跑挂掉的那次会观察到一个稳定的现象：每个事务的日志都打印到 `get account1` 就再也没有下一行 —— 也就是说所有事务都卡在 `SELECT … WHERE id = $1 FOR UPDATE` 这一句。Postgres 之后报 `deadlock detected` 杀掉其中一个事务，剩下的一个继续往下跑。

从代码上看这一句之前并没有任何人显式拿过 `accounts` 这一行的锁，凭什么 `FOR UPDATE` 不能立刻成功？要回答这个，必须看 Postgres 真实持有的锁。

### 用 `pg_locks` 看真正持有的锁

在另一个 psql 会话里，对停在 `get account1` 时的状态做一次：

```sql
SELECT locktype, relation::regclass, mode, granted, pid
FROM pg_locks
WHERE relation = 'accounts'::regclass OR relation IS NULL;
```

会看到：每个事务在 `accounts` 那一行上，都已经持有一把 `ForKeyShare` 锁，状态是 `granted = true`。我们的 Go 代码里从没写过任何针对 `accounts` 的 SELECT 或 UPDATE —— 这把锁是 Postgres 在执行前面的 `INSERT INTO transfers (from_account_id=A, ...)` 和 `INSERT INTO entries (account_id=A, ...)` 时加的。原因是这两个表都把对应字段声明成了 `accounts(id)` 的外键：

```sql
from_account_id bigint REFERENCES accounts(id),
account_id      bigint REFERENCES accounts(id),
```

每次往子表 INSERT 一行，Postgres 都要校验"父行存在 / 在我提交前不会消失或主键被改"，这个校验通过在 `accounts(A)` 上加一把 `FOR KEY SHARE` 锁实现，锁会持有到事务结束。

也就是说，每个事务在做 `FOR UPDATE` 之前，**都已经在 `accounts(A)` 这一行上持有一份 `KEY SHARE`**，这把锁是由外键校验带来的。

### 死锁是怎么形成的

Postgres 行锁的兼容性矩阵里有这样一条：

|              | KEY SHARE | NO KEY UPDATE | UPDATE |
| ------------ | :-------: | :-----------: | :----: |
| KEY SHARE    |           |               |   X    |
| NO KEY UPDATE|           |       X       |   X    |
| UPDATE       |     X     |       X       |   X    |


- `KEY SHARE` 之间不冲突，所以多个事务能**同时**持有同一行的 `KEY SHARE`（这是外键校验能并发的前提）；
- `FOR UPDATE`（`UPDATE` 模式）跟 `KEY SHARE` **冲突**。

把 `accounts(A)` 这一行的时间线画出来：

```
T1                                            T2
─────────────────────────────────────────────────────────────────────────
INSERT transfers(from=A, to=B)
  → FK 校验：在 accounts(A) 上自动持 KEY SHARE
                                              INSERT transfers(from=A, to=B)
                                                → accounts(A) 上自动持 KEY SHARE
                                                  （和 T1 的 KEY SHARE 兼容）
INSERT entries(account_id=A)                  INSERT entries(account_id=A)
  → 还是 KEY SHARE                                → 还是 KEY SHARE

—— 此刻：T1 持 KEY SHARE(A)，T2 也持 KEY SHARE(A) ——

SELECT … WHERE id=A FOR UPDATE
  → 想拿 UPDATE(A)
  → 冲突于 T2 持有的 KEY SHARE(A)
  → 阻塞，等 T2 释放
                                              SELECT … WHERE id=A FOR UPDATE
                                                → 想拿 UPDATE(A)
                                                → 冲突于 T1 持有的 KEY SHARE(A)
                                                → 阻塞，等 T1 释放

⇒ 双方都等对方释放 KEY SHARE(A)，循环等待 ⇒ Postgres 检测出死锁
```

这其实是行锁版本的"读锁升级写锁"经典死锁：每个事务先因为 INSERT 子表被动拿到了 A 上的 `KEY SHARE`，然后又主动想把 A 升到 `UPDATE` —— 升级时既要等别人放掉 KEY SHARE，自己手里那份 KEY SHARE 又卡住别人，循环就出现在**同一行**上。

这里的关键认识有两条：

1. **死锁的两条边里，至少有一条是 Postgres 隐式加的**。Go 代码看上去只显式做了一次 `FOR UPDATE`，但 INSERT 子表那一刻就已经在 `accounts` 上挂上锁了。
2. **`FOR UPDATE` 的"粒度过大"，过在它锁住了主键身份**。`UPDATE` 模式覆盖了主键这一维度，于是哪怕你只想改余额，也会和"别人为了校验主键引用而拿的 `KEY SHARE`"互斥。

把这两条接起来，就能从结构上看出修复的方向：要么阻止 INSERT 自动加 `KEY SHARE`（不可能，FK 语义需要它），要么把更新余额时拿的锁换成一种"承诺不动主键"的更弱形式 —— 这正是下一节 `FOR NO KEY UPDATE` 的来由。

## 改用 `FOR NO KEY UPDATE`

Postgres 提供了一个更弱的行锁 [`FOR NO KEY UPDATE`](https://www.postgresql.org/docs/current/explicit-locking.html#LOCKING-ROWS)，它的语义是："我会更新这一行，但承诺不会改主键 / 唯一键"。这样外键检查时拿到的共享锁就不会和它冲突了。

`db/query/account.sql`：

```sql
-- name: GetAccountForUpdate :one
SELECT * FROM accounts
WHERE id = $1 LIMIT 1
FOR NO KEY UPDATE;
```

重新 `make sqlc`，再把之前为了排查死锁加的 `fmt.Println` 全部清掉（commit `72da0a1`）。

跑测试，外键导致的那种 deadlock 消失了 —— `INSERT` 到 `transfers` 不再被 `accounts` 行锁阻塞。但是当我们扩展测试，让两个账户互相转账（A 转 B、同时 B 转 A）时，会发现新的死锁。

## 第二次死锁：两边事务的环形等待

现实中转账是双向的，写一个新的测试 `TestTransferTxDeadlock`：

```go
func TestTransferTxDeadlock(t *testing.T) {
	store := NewStore(testDB)

	account1 := createRandomAccount(t)
	account2 := createRandomAccount(t)

	n := 10
	amount := int64(10)

	errs := make(chan error)

	for i := 0; i < n; i++ {
		fromAccountID := account1.ID
		toAccountID := account2.ID
		if i%2 == 1 {
			fromAccountID, toAccountID = toAccountID, fromAccountID
		}

		go func() {
			_, err := store.TransferTx(context.Background(), TransferTxParams{
				FromAccountID: fromAccountID,
				ToAccountID:   toAccountID,
				Amount:        amount,
			})

			errs <- err
		}()
	}

	for range n {
		err := <-errs
		require.NoError(t, err)
	}

	// 双向相同次数转账，余额应该回到初始值
	updateAccount1, err := testQueries.GetAccount(context.Background(), account1.ID)
	require.NoError(t, err)

	updateAccount2, err := testQueries.GetAccount(context.Background(), account2.ID)
	require.NoError(t, err)

	require.Equal(t, account1.Balance, updateAccount1.Balance)
	require.Equal(t, account2.Balance, updateAccount2.Balance)
}
```

10 笔转账，按 i 的奇偶交替 A→B / B→A，总金额相互抵消，最后两个账户余额应该和最初一致。

跑这个测试，又出现 `deadlock detected`。原因在事务里两次 `UPDATE` 的顺序：

```
事务 A (1→2):  UPDATE id=1 ✅  → UPDATE id=2 ⏳
事务 B (2→1):  UPDATE id=2 ✅  → UPDATE id=1 ⏳
```

A 拿着 1 的锁等 2，B 拿着 2 的锁等 1，环形等待，死锁。

## 用 `AddAccountBalance` 简化更新

在解决死锁之前，先把"先读余额、再写余额"这种两步式更新替换成一步式，让事务里少持有一次锁。

`db/query/account.sql`：

```sql
-- name: AddAccountBalance :one
UPDATE accounts
SET balance = balance + sqlc.arg(amount)
WHERE id = sqlc.arg(id)
RETURNING *;
```

`sqlc.arg(name)` 是 sqlc 的语法，用来给参数命名，否则 sqlc 会按位置参数生成 `int64, int64` 这样让人分不清的签名。重新 `make sqlc`，得到带命名字段的 `AddAccountBalanceParams`：

```go
type AddAccountBalanceParams struct {
	Amount int64 `json:"amount"`
	ID     int64 `json:"id"`
}
```

然后把 `TransferTx` 里的 `GetAccountForUpdate + UpdateAccount` 两段替换成：

```go
result.FromAccount, err = q.AddAccountBalance(ctx, AddAccountBalanceParams{
	ID:     arg.FromAccountID,
	Amount: -arg.Amount,
})
if err != nil {
	return err
}

result.ToAccount, err = q.AddAccountBalance(ctx, AddAccountBalanceParams{
	ID:     arg.ToAccountID,
	Amount: arg.Amount,
})
if err != nil {
	return err
}
```

这样做有两个好处：
1. 把"读 + 写"合并成一条 `UPDATE`，不再需要 `FOR NO KEY UPDATE` 的显式查询，因为 `UPDATE` 本身就会拿对应行的 `ROW EXCLUSIVE` 锁。
2. 计算 `balance = balance + amount` 是在数据库里完成的，避免把"先读到的旧值"带到 Go 层做减法 —— 即使没有锁，也不会再有 lost update。

注意这一步并没有解决双向转账的死锁，只是把代码精简了。死锁的根因是两个事务以不同的顺序锁两行，跟用不用 `FOR UPDATE` 没关系。

## 解决方案：固定查询顺序

死锁来自两边以"对称相反"的顺序去拿锁。要打破这个循环，让所有事务**不论 from / to 是哪个**，都按账户 ID 从小到大去 `UPDATE`。这样任何两个并发事务对同一对账户的更新顺序都是一致的，不可能形成循环等待。

把 `TransferTx` 里更新两个账户的部分改成：

```go
if arg.FromAccountID < arg.ToAccountID {
	result.FromAccount, result.ToAccount, err = addMoney(
		ctx,
		q,
		arg.FromAccountID,
		-arg.Amount,
		arg.ToAccountID,
		arg.Amount,
	)
} else {
	result.ToAccount, result.FromAccount, err = addMoney(
		ctx,
		q,
		arg.ToAccountID,
		arg.Amount,
		arg.FromAccountID,
		-arg.Amount,
	)
}
if err != nil {
	return err
}
```

辅助函数 `addMoney` 把两次 `AddAccountBalance` 串起来，永远按"先 accountID1 后 accountID2"的顺序更新：

```go
func addMoney(
	ctx context.Context,
	q *Queries,
	accountID1 int64,
	amount1 int64,
	accountID2 int64,
	amount2 int64,
) (account1 Account, account2 Account, err error) {
	account1, err = q.AddAccountBalance(ctx, AddAccountBalanceParams{
		ID:     accountID1,
		Amount: amount1,
	})
	if err != nil {
		return
	}

	account2, err = q.AddAccountBalance(ctx, AddAccountBalanceParams{
		ID:     accountID2,
		Amount: amount2,
	})
	return
}
```

调用方根据 `arg.FromAccountID` 和 `arg.ToAccountID` 的大小关系，决定传给 `addMoney` 的顺序，并相应地把返回的 `account1, account2` 对应回 `result.FromAccount` 或 `result.ToAccount`。

之后再跑 `TestTransferTxDeadlock`，`deadlock detected` 不再出现，最终余额也能回到初始值。

## 小结

把这一节遇到的问题串起来：

| 阶段 | 现象 / 风险 | 解决手段 |
| ---- | ---- | ---- |
| 没加锁，先 SELECT 再 UPDATE | lost update | `SELECT … FOR UPDATE` |
| `FOR UPDATE` 太重 | 外键检查需要的共享锁被排他锁挡住 ⇒ 死锁 | `SELECT … FOR NO KEY UPDATE` |
| 两步更新 | 余额计算回到 Go 层，逻辑啰嗦且容易再触发锁竞争 | `UPDATE accounts SET balance = balance + $1 …`（`AddAccountBalance`） |
| 双向转账时两个事务以相反顺序拿锁 | 环形等待 ⇒ 死锁 | 按账户 ID 升序固定查询顺序 |

Postgres（其实任何关系数据库）的死锁，**绝大多数情况都是事务里以不一致的顺序去拿同一组资源的锁**。光靠选择更弱的锁是治标，最终治本的办法是：

1. 设计一个全局可比较的资源排序（这里用账户 ID 大小）；
2. 在所有事务里强制按这个顺序去访问资源。

下一节会继续在这个 `Store` 之上构建 RESTful HTTP API。
