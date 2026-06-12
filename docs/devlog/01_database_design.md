# 01. 数据库设计

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

使用 [dbdiagram.io](https://dbdiagram.io/) 工具可以导出实体关系图（Entity-Relationship Diagram）

数据库初始设计如下：
![database](../../db01.svg)

## Docker 容器

起一个基于 postgres 镜像的容器

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

使用 [migrate](https://github.com/golang-migrate/migrate) 工具进行数据库迁移：

```bash
migrate create -ext sql -dir db/migration -seq init_schema
```

在 `up` 脚本中填入建表语句

在 `down` 脚本中填入：

```sql
DROP TABLE IF EXISTS entries;
DROP TABLE IF EXISTS transfers;
DROP TABLE IF EXISTS accounts;
```

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

在 Makefile 中包装常用命令

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
