# 01. 数据库设计

这一节先把项目要建模的"东西"理清楚。Simple Bank 要支持的最基础场景就两件事：**给用户开账户** 和 **在账户之间转账**。围绕这两件事，最少需要三张表：

- `accounts`：账户本身，记录持有人、币种、当前余额。
- `entries`：账户的流水（账目变动），每一次余额变化都对应一条记录，金额可正可负。
- `transfers`：转账记录，描述一次"从 A 账户转到 B 账户"的行为，金额恒为正。

`entries` 和 `transfers` 看起来有点重复，但角色完全不同：`transfers` 是"业务事件"（一次转账），`entries` 是"会计流水"（账户余额怎么动的）。一次转账会产生 1 条 `transfers` 记录 + 2 条 `entries` 记录（from 账户一条负数、to 账户一条正数）。这种"事件 / 流水分离"的建模在后面 [04. 数据库事务](./04_database_transaction.md) 里会用上。

## 数据库 schema

```sql
CREATE TABLE "accounts" (
  "id" bigserial PRIMARY KEY,
  "owner" varchar NOT NULL,
  "balance" bigint NOT NULL,
  "currency" varchar NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT (now())
);

CREATE TABLE "entries" (
  "id" bigserial PRIMARY KEY,
  "account_id" bigint NOT NULL,
  "amount" bigint NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT (now())
);

CREATE TABLE "transfers" (
  "id" bigserial PRIMARY KEY,
  "from_account_id" bigint NOT NULL,
  "to_account_id" bigint NOT NULL,
  "amount" bigint NOT NULL,
  "created_at" timestamptz NOT NULL DEFAULT (now())
);

CREATE INDEX ON "accounts" ("owner");

CREATE INDEX ON "entries" ("account_id");

CREATE INDEX ON "transfers" ("from_account_id");

CREATE INDEX ON "transfers" ("to_account_id");

CREATE INDEX ON "transfers" ("from_account_id", "to_account_id");

COMMENT ON COLUMN "entries"."amount" IS 'can be negative or positive';

COMMENT ON COLUMN "transfers"."amount" IS 'must be positive';

ALTER TABLE "entries" ADD FOREIGN KEY ("account_id") REFERENCES "accounts" ("id") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "transfers" ADD FOREIGN KEY ("from_account_id") REFERENCES "accounts" ("id") DEFERRABLE INITIALLY IMMEDIATE;

ALTER TABLE "transfers" ADD FOREIGN KEY ("to_account_id") REFERENCES "accounts" ("id") DEFERRABLE INITIALLY IMMEDIATE;
```

- 金额字段统一用 `bigint`（即 Go 中的 `int64`），用整数就暂时不用操心浮点数的精度问题。
- `created_at` 用 `timestamptz`（带时区），由数据库 `now()` 兜底，应用层不需要传时间。
- 三张表上加的索引都是为了支持后面"按 owner 查账户"、"按账户查流水/转账记录"这类典型查询。
- 外键加了 `DEFERRABLE INITIALLY IMMEDIATE`：默认仍然在每条语句结束时检查约束，但保留了在事务里 `SET CONSTRAINTS ALL DEFERRED` 把检查推迟到事务提交时的能力，给某些"先插入子表、再补父表"的批量操作留口子。

使用 [dbdiagram.io](https://dbdiagram.io/) 工具可以导出实体关系图（Entity-Relationship Diagram）

数据库初始设计如下：
![database](../../db01.svg)

## Docker 容器

起一个基于 postgres 镜像的容器：

```bash
docker run --name pg18 -p 5432:5432 -e POSTGRES_USER=root -e POSTGRES_PASSWORD=secret -d postgres:18-alpine
```

使用容器中的 `createdb` 工具创建数据库：

```bash
docker exec -it pg18 createdb --username=root --owner=root simple_bank
```

> `-i` 让你能向容器输入，`-t` 让你看到漂亮的终端输出，两者组合才能获得完整的交互式终端体验，就像 SSH 到一台远程机器一样。

使用容器中的 `dropdb` 工具删除数据库：

```bash
docker exec -it pg18 dropdb simple_bank
```

## 数据库迁移脚本

schema 不能只活在某个 GUI 工具或者某个开发者的脑子里 —— 它必须是**版本化、可重放**的脚本，CI、本地、线上都按同一份 SQL 走一遍，结果应当一致。这就是数据库迁移要解决的问题。

使用 [migrate](https://github.com/golang-migrate/migrate) 工具进行数据库迁移：

```bash
migrate create -ext sql -dir db/migration -seq init_schema
```

这条命令会在 `db/migration/` 下生成一对脚本：`000001_init_schema.up.sql` 和 `000001_init_schema.down.sql`。`up` 描述"如何把 schema 推进到这一版"，`down` 描述"如何回退"。每次需要修改 schema，就再 `migrate create` 一对新的 `00000N_xxx.{up,down}.sql`，永远只往前加迁移，不去改历史脚本。

在 `up` 脚本中填入建表语句

在 `down` 脚本中填入：

```sql
DROP TABLE IF EXISTS entries;
DROP TABLE IF EXISTS transfers;
DROP TABLE IF EXISTS accounts;
```

> `accounts` 放最后删，是因为 `entries` / `transfers` 通过外键引用了它，必须先把引用方清掉。

使用 `up` 子命令初始化数据库中的表：

```bash
migrate -path db/migration -database "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable" -verbose up
```

> 本地通过 Docker 启动的 PostgreSQL 容器默认没有配置 SSL 证书，而 `migrate` 工具默认会尝试使用 SSL 连接数据库。如果不显式禁用 SSL，连接时会报错 `SSL is not enabled on the server`

使用 `down` 子命令进行回退：

```bash
migrate -path db/migration -database "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable" -verbose down
```

## 用 Makefile 包装常用命令

上面这些命令长、参数多、又会被反复用到，每次手敲既容易出错又劝退。把它们沉到 `Makefile` 里，开发时只需要 `make postgres` / `make migrateup` 就够了，后续节也会沿用这个习惯，把新工具的命令都加进来。

```makefile
postgres:
	docker run --name pg18 -p 5432:5432 -e POSTGRES_USER=root -e POSTGRES_PASSWORD=secret -d postgres:18-alpine

createdb:
	docker exec -it pg18 createdb --username=root --owner=root simple_bank

dropdb:
	docker exec -it pg18 dropdb simple_bank

migrateup:
	migrate -path db/migration -database "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable" -verbose up

migratedown:
	migrate -path db/migration -database "postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable" -verbose down

.PHONY: postgres createdb dropdb migrateup migratedown
```
