# 13. 把服务容器化

到 [12. Token 认证](./12_token_authentication.md) 为止，整个服务在功能上已经能跑：注册、登录、转账、authorization 都打通了。但启动它仍然需要本地有 Go 工具链、装好 `golang-migrate`，再配合 Makefile 里 `docker run postgres ...` / `make migrateup` / `make server` 一连串命令依次跑起来。换一台机器，整个流程要重来一遍。

这一节的目标是把这套 "怎么跑" 固化下来：

1. 用一个多阶段 `Dockerfile` 把服务编译并打包成最小镜像；
2. 让 API 容器和 Postgres 容器通过 docker 自定义网络互相找到；
3. 用 `docker-compose` 编排两个容器，并控制启动顺序：等 Postgres 健康后再起 API，API 启动时先做迁移再起服务。

## 多阶段构建：编译镜像和运行镜像分开

最直接的写法是基于 `golang:1.25` 这种带完整 Go 工具链的镜像，把代码 `COPY` 进去，`go build` 完直接 `CMD` 跑二进制。问题是这种镜像本身就有几百 MB —— 它带着 Go 编译器、`go.mod` 缓存目录、各种 build 期才需要的工具。但**真正运行**这个服务，只需要一个静态链接的 Linux 二进制。

Docker 的 [multi-stage build](https://docs.docker.com/build/building/multi-stage/) 就是为这种场景设计的：在一个 `Dockerfile` 里写多个 `FROM`，前面的阶段只用来构建产物，最后一个阶段从前面的阶段里 `COPY --from=<stage>` 把需要的文件挑出来。前面那些阶段不会出现在最终镜像里。

第一版 `Dockerfile`：

```dockerfile
# Build stage
FROM golang:1.25-alpine3.23 AS builder
WORKDIR /app
COPY . .
RUN go build -o main main.go

# Run stage
FROM alpine:3.23
WORKDIR /app
COPY --from=builder /app/main .

EXPOSE 8080
CMD [ "/app/main" ]
```

- **build stage 用 `golang:1.25-alpine3.23`，run stage 用 `alpine:3.23`**：两个阶段共用 alpine 作为基底，避免 glibc / musl 链接不上的问题（Go 在 alpine 下默认走 CGO_ENABLED=0 的纯静态构建，更省心）。
- **`AS builder`** 给第一个阶段起个名字，第二个阶段才能 `COPY --from=builder` 引用它。
- **`COPY . .`** 把整个仓库打进 builder。这里依赖 `.dockerignore`（如果有）排除掉 `.git/`、`tmp/` 之类不需要的东西；项目目前还没有这个文件，但后续如果 build 上下文太大，加上 `.dockerignore` 是常规优化。
- **`go build -o main main.go`**：编译入口在仓库根目录的 `main.go`，输出二进制名字叫 `main`。
- **`COPY --from=builder /app/main .`** 把 builder 里编译好的二进制复制到运行镜像的 `/app/main`。
- **`EXPOSE 8080`** 是文档性质的声明，告诉镜像使用者这个容器对外提供 8080。它本身不会做端口映射，真正映射要在 `docker run -p` 或 docker-compose 里写。
- **`CMD [ "/app/main" ]`** 用 exec 形式（数组写法），让 PID 1 直接是这个二进制，能正确接收 `SIGTERM` 之类的信号。

构建并跑起来：

```bash
docker build -t simplebank:latest .
docker run --rm -p 8080:8080 simplebank:latest
```

到这一步镜像能跑了，但马上会遇到两个问题：第一，启动后没有 `app.env`，配置全靠默认值；第二，连 `localhost:5432` 连不上，因为容器里没有 Postgres。

第一个问题先打个补丁，把配置文件也复制到运行镜像：

```dockerfile
# Run stage
FROM alpine:3.23
WORKDIR /app
COPY --from=builder /app/main .
COPY app.env .

EXPOSE 8080
CMD [ "/app/main" ]
```

`app.env` 里的 `DB_SOURCE` 写死的是 `postgresql://root:secret@localhost:5432/...`，等下要让它指到真正的 Postgres 容器上。

## 让 API 容器找到 Postgres 容器

把 API 镜像跑起来：

```bash
docker run --name api -p 8080:8080 simplebank:latest
```

启动会失败，错误大概是 `dial tcp 127.0.0.1:5432: connect: connection refused`。容器里的 `localhost` 是**容器自己的网络命名空间**，不是宿主机，更不是 Postgres 容器。两个容器要互相通信，就得让它们在同一个网络里，并通过名字（DNS）找到对方。

### Docker 默认的 bridge 网络

`docker run` 不指定 `--network` 时，容器默认接到一个叫 `bridge` 的网络上。它有两个限制：

- **容器之间默认不能通过容器名互相 resolve**：默认 bridge 不开启容器名 DNS 解析，只能用 IP 互访，而容器 IP 又是动态的；
- **隔离性弱**：所有用 `bridge` 起的容器都在同一个网络里，没法做分组。

### 自定义 bridge 网络

更好的做法是创建一个自定义 bridge 网络。在自定义网络里，docker 会自动给每个加入的容器注册一个内部 DNS 记录，名字就是容器的 `--name`：

```bash
docker network create bank-network
```

然后让 Postgres 容器加入这个网络：

```makefile
postgres:
	docker run --name pg18 --network bank-network -p 5432:5432 \
		-e POSTGRES_USER=root -e POSTGRES_PASSWORD=secret -d postgres:18-alpine
```

`-p 5432:5432` 仍然保留，这样宿主机上的 `psql`、`migrate` 还能照常连。容器之间走的是另一条路径：在 `bank-network` 内部，任何容器只要写 `pg18:5432` 就能连到 Postgres。

API 容器跑起来时也加入这个网络，并把 `DB_SOURCE` 里的 `localhost` 换成 `pg18`：

```bash
docker run --name api --network bank-network -p 8080:8080 \
    -e DB_SOURCE="postgresql://root:secret@pg18:5432/simple_bank?sslmode=disable" \
    simplebank:latest
```

`-e` 传进去的环境变量会**覆盖** `app.env` 里同名的配置 —— 这是 [`viper.AutomaticEnv()`](./07_config_management.md) 的优先级规则。这样镜像里那份 `app.env` 写的是开发机视角的连接串，部署到容器里时由外部环境变量重新指定。

到这里两个容器已经能互相通信，但还有两件事手动做着烦：每次都要 `docker network create`，每次都要记一长串 `docker run` 参数。这正是 docker-compose 要解决的问题。

## 用 docker-compose 编排

`docker-compose.yaml` 把 "起哪几个容器、怎么起、它们怎么连" 写在一份声明式配置里，一条 `docker compose up` 就能拉起来。

```yaml
name: simple_bank
services:
  postgres:
    image: postgres:18-alpine
    ports:
      - "5432:5432"
    environment:
      - POSTGRES_USER=root
      - POSTGRES_PASSWORD=secret
      - POSTGRES_DB=simple_bank
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U root -d simple_bank"]
      interval: 2s
      timeout: 5s
      retries: 5
      start_period: 5s
  api:
    build:
      context: .
      dockerfile: Dockerfile
    ports:
      - "8080:8080"
    environment:
      - DB_SOURCE=postgresql://root:secret@postgres:5432/simple_bank?sslmode=disable
    depends_on:
      postgres:
        condition: service_healthy
```

读这份文件几个关键点：

- **`name: simple_bank`** 是这个 compose 项目的名字。compose 会基于它生成网络名（`simple_bank_default`）、容器名前缀等。它取代了上一节手动 `docker network create bank-network`：compose 默认会给项目内所有 service 建一个共用的 bridge 网络，service 的 key（`postgres` / `api`）就是它在这个网络里的 DNS 名。所以 `DB_SOURCE` 里写的是 `postgres:5432`，不再是上一节的 `pg18:5432`。
- **`postgres` service**：直接用官方 `postgres:18-alpine` 镜像。`environment:` 里设置的是 Postgres 容器初始化用的几个变量 —— 这一套和 [05. CI workflow](./05_ci_workflow.md#第二版挂上-postgres-service) 里 service container 的写法是同一回事，因为 GitHub Actions 的 service container 底层也是这套 compose 风格的 spec。`POSTGRES_DB` 让容器第一次启动时就把 `simple_bank` 库建好，省掉单独的 `createdb` 步骤。
- **`api` service**：`build:` 块告诉 compose "这个 service 没有现成镜像，去 `context: .` 目录下用 `dockerfile: Dockerfile` 构建一份"。compose up 时会自动 `docker build`。
- **`depends_on` 和 `healthcheck`**：这两块组合起来才是 "等 Postgres 真的能用了再起 API" 的关键，下一节单独讲。

`docker compose up` 起来之后，整套服务就能跑起来；`docker compose down` 一键全清。

## 启动顺序：`depends_on` 不够，要配合 healthcheck

最朴素的写法是 `depends_on: [postgres]`。这只能保证 **API 容器在 Postgres 容器进程启动后才启动** —— 但 "进程启动" 不等于 "数据库可以接受连接"：Postgres 容器起来后，内部还要做初始化、apply 默认配置、绑定端口监听，这之间有几秒钟的时间窗口。如果 API 在这个窗口里启动，连过去会拿到 `connection refused`，启动直接失败。

[CI workflow 那一节](./05_ci_workflow.md#第二版挂上-postgres-service) 处理过同样的问题，方案是给 service 容器加 healthcheck，让 GitHub Actions 等容器变成 healthy 之后再跑 step。compose 这边走的是同一思路：

```yaml
postgres:
  ...
  healthcheck:
    test: ["CMD-SHELL", "pg_isready -U root -d simple_bank"]
    interval: 2s
    timeout: 5s
    retries: 5
    start_period: 5s
api:
  ...
  depends_on:
    postgres:
      condition: service_healthy
```

healthcheck 的字段含义：

- **`test`**：探活命令。`pg_isready` 是 Postgres 自带的小工具，专门用来检查 server 是否准备好接受连接，返回 0 表示 ready；
- **`interval: 2s`**：每 2 秒探一次；
- **`timeout: 5s`**：单次探活超过 5 秒视作失败；
- **`retries: 5`**：连续失败 5 次才把容器判为 unhealthy；
- **`start_period: 5s`**：启动后给一个 5 秒宽限期，这段时间内的失败不计入 retries。

`depends_on` 升级成 `condition: service_healthy` 之后，compose 会真正等 Postgres healthcheck 通过再启动 API。

## 启动时先迁移数据库再起服务

到这一步 API 容器一启动就能连上 Postgres 了，但它面对的是一个**完全空**的 `simple_bank` 库 —— `accounts` / `users` / `entries` / `transfers` 这些表都还没建。本地开发时这一步是 `make migrateup` 单独跑的；放进容器里就要换个思路：让容器**自己**跑迁移，跑完再 exec 主进程。

这件事拆成两个变更：把 `migrate` CLI 打进运行镜像，写一个 entrypoint 脚本去串起来。

### 把 migrate 打进 builder

`Dockerfile` 的 builder 阶段加一段：

```dockerfile
FROM golang:1.25-alpine3.23 AS builder
WORKDIR /app
COPY . .
SHELL [ "/bin/ash", "-o", "pipefail", "-c" ]
RUN go build -o main main.go
RUN apk add --no-cache curl
RUN curl -L https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz | tar xvz
```

- **`SHELL [ "/bin/ash", "-o", "pipefail", "-c" ]`**：alpine 默认的 shell 是 `/bin/sh`（busybox `ash`），管道里前面命令失败时整条管道仍然返回 0。开 `pipefail` 后，`curl ... | tar xvz` 里 curl 失败会让整条 RUN 失败，避免悄悄打了个不完整的镜像。
- **`apk add --no-cache curl`**：alpine 默认不带 curl，`--no-cache` 让 apk 不留索引文件构建层更小。
- **`curl -L ... | tar xvz`** 直接把 [golang-migrate](https://github.com/golang-migrate/migrate) 的 release 二进制下载并解压，得到 `/app/migrate`。这一招在 [CI workflow](./05_ci_workflow.md#第三版在-runner-上安装-golang-migrate) 装 migrate 时已经用过，思路是一样的。

run stage 把 `migrate` 二进制和 `db/migration/` 目录都复制过去，再带上 entrypoint 脚本：

```dockerfile
FROM alpine:3.23
WORKDIR /app
COPY --from=builder /app/main .
COPY --from=builder /app/migrate .
COPY app.env .
COPY db/migration ./migration
COPY start.sh .

EXPOSE 8080
CMD [ "/app/main" ]
ENTRYPOINT [ "/app/start.sh" ]
```

`db/migration/` 里就是 `000001_init_schema.up.sql` 这一系列文件，迁移工具靠它们建表。

### `start.sh`：先迁移、再起服务

```sh
#!/bin/sh

set -e

echo "run db migration"
/app/migrate -path /app/migration -database "$DB_SOURCE" -verbose up

echo "start the app"
exec "$@"
```

几个细节值得拆开看：

- **`set -e`**：脚本里任何一条命令失败就立刻退出。
- **`migrate ... up`**：`-path /app/migration` 是迁移文件目录，`-database "$DB_SOURCE"` 用容器里收到的环境变量做连接串（compose 里的 `DB_SOURCE` 指向 `postgres:5432`）。
- **`exec "$@"`**：这是 entrypoint 模式的关键。

### `CMD` + `ENTRYPOINT` 的协作

`Dockerfile` 末尾两行常被一起写但分工很明确：

- `ENTRYPOINT` 决定**容器进程是什么**；
- `CMD` 是**默认传给 ENTRYPOINT 的参数**，可以在 `docker run` 命令行覆盖。

写成这样：

```dockerfile
CMD [ "/app/main" ]
ENTRYPOINT [ "/app/start.sh" ]
```

容器启动时实际跑的是 `/app/start.sh /app/main`。在脚本里 `"$@"` 就等于 `"/app/main"`。`exec` 会**用 `/app/main` 替换当前 shell 进程**，不创建子进程 —— 这样 PID 1 就是 Go 二进制本身，能正确接收 docker 发来的 `SIGTERM`、`SIGINT`，做优雅退出。否则 PID 1 是 `start.sh`，shell 默认不转发信号，容器停止时就会一直等到超时被强杀。

带来的好处是：

- **平时**：`docker compose up` → 容器跑 `start.sh /app/main` → 先迁移再起服务；
- **要 debug**：`docker run --rm -it simplebank /bin/sh` → 这条命令把 CMD 覆盖成 `/bin/sh`，`start.sh` 里 `exec "$@"` 就会去起 shell。但迁移那一步还是会先跑 —— 这通常不是想要的。要彻底跳过 entrypoint，加 `--entrypoint /bin/sh`。

## 小结

到这里整个服务从 "本地开发机才跑得起来" 变成了 "任何装了 docker 的机器一句 `docker compose up` 就跑起来"：

- **多阶段 Dockerfile** 把构建产物和运行环境分开，最终镜像基于 alpine，只装了二进制 + migrate + 迁移文件 + 启动脚本；
- **docker-compose.yaml** 描述清楚了拓扑（API + Postgres）、网络（默认 bridge，service 名作为 DNS）、健康检查（`pg_isready` + `service_healthy`）、启动顺序；
- **`start.sh` + `ENTRYPOINT` + `CMD`** 把 "迁移 → 起服务" 两件事缝在容器启动里，应用进程作为 PID 1 接收信号。

这套东西也是后续部署到 ECS / Kubernetes / 云厂商容器服务的基础 —— 镜像本身不变，外部只换网络和编排。
