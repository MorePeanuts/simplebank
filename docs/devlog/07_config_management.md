# 07. 配置管理

到上一节为止，数据库连接串、监听地址都还是写死在源码里的常量：

```go
// main.go
const (
	dbDriver      = "postgres"
	dbSource      = "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable"
	serverAddress = "0.0.0.0:8080"
)
```

```go
// db/sqlc/main_test.go
const (
	dbDriver = "postgres"
	dbSource = "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable"
)
```

本节的目标：**把这些会随环境变化的值从代码里搬出去**，让它们：

1. 默认从一个本地的配置文件（`app.env`）里读，方便本地开发；
2. 同名的环境变量能覆盖配置文件里的值，方便 CI / Docker / Kubernetes 这些通过环境变量注入配置的场景；
3. 应用启动时一次性读完，全程当成一个 `Config` 结构体往下传，业务代码不用关心配置是从哪里来的。

Go 生态里做配置管理的库不少（[viper](https://github.com/spf13/viper)、[koanf](https://github.com/knadh/koanf)、[envconfig](https://github.com/kelseyhightower/envconfig) 等），它们的能力高度重叠。本项目选 [viper](https://github.com/spf13/viper)

```bash
go get github.com/spf13/viper
```

## 配置文件 `app.env`

新建项目根目录下的 `app.env`：

```env
DB_DRIVER='postgres'
DB_SOURCE='postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable'
SERVER_ADDRESS='0.0.0.0:8080'
```

几个选择上的细节：

- 文件格式选了 `.env`（key=value，每行一条），而不是 `yaml` / `toml`。一方面这套配置目前都是扁平的标量，没有嵌套；另一方面 `.env` 和环境变量天然同构，调试时心智负担最低。viper 内部用 [godotenv](https://github.com/joho/godotenv) 解析这种格式。
- key 全部使用 `SCREAMING_SNAKE_CASE`，和环境变量的惯例一致。viper 在做"环境变量覆盖配置文件"的时候是按 key 同名匹配的，配置文件里的 key 直接采用环境变量的写法，能省掉一层名字转换。
- 文件名叫 `app.env` 而不是 `.env`，是为了把"应用配置"和"shell / docker compose 默认会自动加载的 `.env`"区分开。后者有自己的语义（被 docker compose、direnv 这类工具用）。
- **本地开发可以提交一份带占位符或默认值的 `app.env` 进 git**，但生产用的真实密码、密钥之类**绝不应该提交**。

## `util.Config` 与 `LoadConfig`

新建 `util/config.go`，把"配置长什么样 + 怎么加载"封装成一个独立的工具包：

```go
package util

import "github.com/spf13/viper"

// Config stores all configuration of the application.
// The values are read by viper from a config file or environment variables.
type Config struct {
	DBDriver      string `mapstructure:"DB_DRIVER"`
	DBSource      string `mapstructure:"DB_SOURCE"`
	ServerAddress string `mapstructure:"SERVER_ADDRESS"`
}

// LoadConfig reads configuration from file or environment variables.
func LoadConfig(path string) (config Config, err error) {
	viper.AddConfigPath(path)
	viper.SetConfigName("app")
	viper.SetConfigType("env")

	viper.AutomaticEnv()

	err = viper.ReadInConfig()
	if err != nil {
		return
	}

	err = viper.Unmarshal(&config)
	return
}
```

- `Config` 是整个应用的配置形状，所有字段都用 `mapstructure` 标签把"结构体字段名"和"配置 key"绑起来。这里用的是 `mapstructure` 而不是 `json`：viper 内部走的是 [mapstructure](https://github.com/mitchellh/mapstructure) 这条路径，`json` 标签它不认。Go 字段名（`DBDriver`）和环境变量名（`DB_DRIVER`）不一样，一定要显式标注。
- `SetConfigName("app") + SetConfigType("env")` 组合起来，告诉 viper "去找一个叫 `app` 的、`.env` 格式的文件"，最终匹配的就是 `app.env`。
- `AutomaticEnv()` 告诉 viper "如果存在同名环境变量，环境变量的值优先于配置文件"。这样同一个二进制在不同环境下不需要重新构建，只要在启动前 `export DB_SOURCE=...` 就能切换；CI / Docker 那边也只要往容器里注入环境变量就行。

## 替换硬编码常量

把 `main.go` 里的常量块整个删掉，换成调用 `util.LoadConfig`：

```go
package main

import (
	"database/sql"
	"log"

	"github.com/MorePeanuts/simplebank/api"
	db "github.com/MorePeanuts/simplebank/db/sqlc"
	"github.com/MorePeanuts/simplebank/util"
	_ "github.com/lib/pq"
)

func main() {
	config, err := util.LoadConfig(".")
	if err != nil {
		log.Fatal("cannot load configuration:", err)
	}

	conn, err := sql.Open(config.DBDriver, config.DBSource)
	if err != nil {
		log.Fatal("cannot connect to db:", err)
	}

	store := db.NewStore(conn)
	server := api.NewServer(store)

	err = server.Start(config.ServerAddress)
	if err != nil {
		log.Fatal("cannot start server:", err)
	}
}
```

原本三行 `const` 现在被一行 `LoadConfig(".")` 取代，并且增加了"环境变量覆盖"这一层能力。

`db/sqlc/main_test.go` 之前也维护了一份独立的 `dbDriver` / `dbSource`，这里一并迁移：

```go
package db

import (
	"database/sql"
	"log"
	"os"
	"testing"

	"github.com/MorePeanuts/simplebank/util"
	_ "github.com/lib/pq"
)

var (
	testQueries *Queries
	testDB      *sql.DB
)

func TestMain(m *testing.M) {
	config, err := util.LoadConfig("../..")
	if err != nil {
		log.Fatal("cannot load configuration:", err)
	}

	testDB, err = sql.Open(config.DBDriver, config.DBSource)
	if err != nil {
		log.Fatal("cannot connect to db:", err)
	}

	testQueries = New(testDB)

	os.Exit(m.Run())
}
```

## "环境变量覆盖"是怎么生效的

viper 内部维护的是一个**带优先级的多源合并**：

```
显式 Set > flag > 环境变量 > 配置文件 > key/value store > 默认值
```

`AutomaticEnv()` 干的事，就是在 `Get("DB_SOURCE")` 时去查一下进程的环境变量，如果存在就用环境变量的值替代配置文件里的

## 小结

| 改动 | 解决的问题 |
| ---- | ---- |
| 新增 `app.env` | 把变化的配置从源码里搬出去，按环境变量的命名习惯组织 |
| 新增 `util.Config` 和 `util.LoadConfig` | 用一个结构体描述"配置长什么样"，加载路径作为入参以便复用 |
| `main.go` 改用 `LoadConfig(".")` + `viper.AutomaticEnv()` | 启动期一次性读完配置，环境变量自动覆盖文件里的同名值 |
| `db/sqlc/main_test.go` 同步改造 | 测试和应用共用同一份配置，避免 DB 连接串两处漂移 |


下一节会回到 HTTP API，给上一章写好的几个 handler 补上单元测试 —— 直接打真实数据库的测试已经在 CRUD 那层写过了，handler 这一层换一种打法，用 mock 把 `Store` 替掉，专心测"参数校验 / 状态码 / JSON 形状"这几件事。
