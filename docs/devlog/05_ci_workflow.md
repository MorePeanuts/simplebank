
# 05. 持续集成（CI）

**CI（Continuous Integration，持续集成）** 是一种开发实践：开发者把代码变更频繁地合入主干分支，每一次合入都触发一套自动化流程，去构建项目、跑测试、做静态检查，第一时间反馈"这次变更是否破坏了已有的东西"。

每次 `push` 或开 PR，都在一个**干净、可复现**的环境里跑构建和测试，结果直接挂在 commit / PR 上作为状态检查。出问题就立刻挂红，pinpoint 到具体哪个 commit 引入的；测试都过了，reviewer 才有信心点 merge。

这一节的目标，是把这套流程搬到 [GitHub Actions](https://docs.github.com/en/actions) 上去：每次 `push` 到 `main` 或者向 `main` 提 PR 时，让 CI 自动起一个 Postgres、跑迁移、再跑全部 `go test`，把"测试通过/失败"这个信号持续暴露出来。

## GitHub Actions 的基本概念

在写 workflow 文件之前，先把 [GitHub Actions](https://docs.github.com/en/actions) 里几个反复出现的名词理清楚：

- **Workflow**：一次完整的自动化流程，由一个放在 `.github/workflows/` 下的 YAML 文件描述。每个仓库可以有多个 workflow（比如 ci、release、deploy 各一个）。
- **Event**：触发 workflow 的事件，例如 `push`、`pull_request`、`schedule`、`workflow_dispatch` 等。
- **Job**：workflow 里的一个执行单元，跑在一个独立的 runner（虚拟机）上。一个 workflow 可以并行/串行地跑多个 job。
- **Runner**：实际执行 job 的机器，可以是 GitHub 托管的（如 `ubuntu-latest`），也可以是自建的（self-hosted）。
- **Step**：job 内部按顺序执行的一步，可以是一条 shell 命令（`run:`），也可以是一个复用的 action（`uses:`）。
- **Action**：被打包好的可复用步骤，比如 `actions/checkout` 用来把仓库代码 checkout 到 runner 上，`actions/setup-go` 用来在 runner 上装一个指定版本的 Go。
- **Service container**：在 job 期间额外跑一个 Docker 容器，最常见的用途就是给测试提供数据库、缓存这类外部依赖。

整个 CI 的结构就是 "事件触发 workflow → workflow 调度若干 job → job 在 runner 上按顺序跑若干 step（可以挂上若干 service container）"。

## 第一版：只跑 `make test`

新建 `.github/workflows/ci.yml`，先写最小可跑的骨架：

```yaml
name: ci-test

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  test:
    name: Test
    runs-on: ubuntu-latest
    steps:
      - name: Set up Go 1.x
        uses: actions/setup-go@v2
        with:
          go-version: ^1.25
        id: go

      - name: Check out code into the Go module directory
        uses: actions/checkout@v2

      - name: Test
        run: make test
```

几个关键点：

- `name: ci-test` 是 workflow 的展示名，会出现在 GitHub 的 Actions 页面以及 commit / PR 的状态检查里。
- `on:` 配置触发条件。这里限定为：往 `main` 分支的 `push`，以及目标分支是 `main` 的 `pull_request`。这样既能保证 main 上每次合入都跑 CI，也能在 PR 阶段就提前看到测试结果。
- `runs-on: ubuntu-latest` 让 GitHub 给我们分配一台最新的 Ubuntu 虚拟机作为 runner。
- 两个 `uses:` 引入了官方提供的 action：
  - `actions/setup-go@v2` 在 runner 上安装 Go。`go-version: ^1.25` 是 [semver](https://semver.org/) 风格的范围匹配，意思是"用 1.x 中 ≥ 1.25 的最新版本"，这样不用每次升 minor 都改 workflow。
  - `actions/checkout@v2` 把当前仓库 checkout 到 runner 的工作目录里。**这一步必须有**，否则 runner 上没有源码，后面 `make test` 找不到代码。
- `run: make test` 直接复用 [Makefile 里的 `test` 目标](./03_unit_test_for_crud.md#在-makefile-中加入-test-目标)，等价于 `go test -v -cover ./...`。

把这一版 push 上去，CI 会失败 —— 因为我们的测试要连 `postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable`，而 runner 上根本没有 Postgres。

## 第二版：挂上 Postgres service

GitHub Actions 提供了 [service container](https://docs.github.com/en/actions/using-containerized-services/about-service-containers) 机制：在 job 里声明一个 `services:` 块，runner 启动后会先帮我们跑起对应的容器，job 跑完再清理掉，整个生命周期由 Actions 管理。

```yaml
jobs:
  test:
    name: Test
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:18-alpine
        env:
          POSTGRES_USER: root
          POSTGRES_PASSWORD: postgres
          POSTGRES_DB: simple_bank
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      # ... setup-go / checkout 同上 ...

      - name: Run migrations
        run: make migrateup

      - name: Test
        run: make test
```

要点：

- `image: postgres:18-alpine` 用的是和本地开发完全一致的镜像（见 [Makefile 中的 `postgres` 命令](../../Makefile)）。
- `env:` 里设置 Postgres 容器初始化所需的几个环境变量。`POSTGRES_USER` / `POSTGRES_PASSWORD` 决定超级用户，`POSTGRES_DB` 让容器在第一次启动时自动创建对应的数据库 —— 这就把本地需要 `make createdb` 才能完成的事直接前置到了容器启动里。
- `options:` 配的是 `docker run` 的额外参数。这里挂了 4 个 `--health-*` 参数，本质是给容器加上 healthcheck：每 10 秒跑一次 `pg_isready`，超时 5 秒，最多重试 5 次。GitHub Actions 会等到 service 容器变成 healthy 之后，才让 job 的 `steps` 开始跑，这样后续步骤连 Postgres 时不会因为 "数据库还没起来" 而报 "connection refused"。
- 在跑测试之前加了一步 `make migrateup`，把 `db/migration/` 下的 schema 应用到 CI 里这个新创建的 `simple_bank` 数据库上。

但这一版还差两块拼图：runner 上还没有 `migrate` 命令；以及，job 里的 step 默认是直接跑在 runner 主机上的，得能访问到 service 容器里的 Postgres。下面分别处理。

## 第三版：在 runner 上安装 `golang-migrate`

`make migrateup` 调用的是 [golang-migrate](https://github.com/golang-migrate/migrate) 提供的 `migrate` CLI，runner 默认没有，需要自己装。常见方案是直接下载官方发布的二进制：

```yaml
      - name: Install golang-migrate
        run: |
          curl -L https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz | tar xvz
          sudo mv migrate /usr/bin/
          which migrate
```

几个细节：

- 用 `|` 写多行 shell：每一行都会被同一个 shell 进程执行，比较直观。
- 第一行 `curl -L ... | tar xvz`：`-L` 让 curl 跟随重定向（GitHub release 的下载链接会跳转到 CDN），管道直接喂给 `tar xvz`，避免在磁盘上留临时压缩包。`xvz` = `extract + verbose + gzip`。
- 解压出来的是个名为 `migrate` 的二进制，用 `sudo mv migrate /usr/bin/` 放到 `PATH` 里，让后续的 `make migrateup` 直接能找到它。
- 最后 `which migrate` 是一个简单的自检：在 CI 日志里打印出 `migrate` 的实际位置，部署/排查时能少走弯路。

同时把 `POSTGRES_PASSWORD` 从最初占位用的 `postgres` 改回项目里实际使用的 `secret`，这样 `make migrateup` 里写死的连接串 `postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable` 才能连上 service 容器。

## 第四版：把 Postgres 端口映射到 host

跑到这里 CI 还是连不上 Postgres，错误大概是 `dial tcp 127.0.0.1:5432: connect: connection refused`。原因是：在 GitHub Actions 上，**job 的 step 默认跑在 runner 的 host 上，而不是某个容器里**。host 和 service 容器之间是 Docker 默认的 bridge 网络，service 容器里 Postgres 监听的 5432 并不会自动暴露到 host。

解决办法是在 service 配置里显式做端口映射：

```yaml
    services:
      postgres:
        image: postgres:18-alpine
        env:
          POSTGRES_USER: root
          POSTGRES_PASSWORD: secret
          POSTGRES_DB: simple_bank
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
```

`ports: - 5432:5432` 等价于 `docker run -p 5432:5432`：把容器的 5432 端口绑到 host 的 5432 上。这样 host 上跑的 `migrate` 和 `go test` 通过 `localhost:5432` 就能连进容器里的 Postgres，整条链路打通。

> 题外话：如果用 [container jobs](https://docs.github.com/en/actions/using-jobs/running-jobs-in-a-container)（在 job 上加 `container:`）让 step 也跑在容器里，那么 step 容器和 service 容器是在同一个 user-defined network 里，可以直接用 `postgres:5432` 这种 service name 互访，不需要再做端口映射。本项目的 step 就是普通的 host runner，所以选了端口映射的方案。

## 最终的 `ci.yml`

把上面四步合在一起，最终的 `.github/workflows/ci.yml` 长这样：

```yaml
name: ci-test

on:
  push:
    branches:
      - main
  pull_request:
    branches:
      - main

jobs:
  test:
    name: Test
    runs-on: ubuntu-latest
    services:
      postgres:
        image: postgres:18-alpine
        env:
          POSTGRES_USER: root
          POSTGRES_PASSWORD: secret
          POSTGRES_DB: simple_bank
        ports:
          - 5432:5432
        options: >-
          --health-cmd pg_isready
          --health-interval 10s
          --health-timeout 5s
          --health-retries 5
    steps:
      - name: Set up Go 1.x
        uses: actions/setup-go@v2
        with:
          go-version: ^1.25
        id: go

      - name: Check out code into the Go module directory
        uses: actions/checkout@v2

      - name: Install golang-migrate
        run: |
          curl -L https://github.com/golang-migrate/migrate/releases/download/v4.19.1/migrate.linux-amd64.tar.gz | tar xvz
          sudo mv migrate /usr/bin/
          which migrate

      - name: Run migrations
        run: make migrateup

      - name: Test
        run: make test
```

整个 job 的执行顺序：

1. GitHub Actions 收到 `push` / `pull_request` 事件，分配一台 `ubuntu-latest` runner；
2. 在 runner 旁边并行启动 `postgres:18-alpine` service 容器，等它 health check 通过；
3. `actions/setup-go` 装好 Go 1.25+；
4. `actions/checkout` 把代码 checkout 出来；
5. 下载并安装 `migrate` CLI；
6. `make migrateup` 把 schema 推到 service 容器里的 `simple_bank`；
7. `make test` 跑 `go test -v -cover ./...`，连 `localhost:5432` 上 service 容器里的 Postgres，跑完所有单元测试和事务测试。

## 小结


| commit | 做了什么 | 解决的问题 |
| ---- | ---- | ---- |
| `284b99c` | 写出最小 workflow，跑 `make test` | 让事件能触发 CI、能装 Go、能 checkout 代码 |
| `3c5c85b` | 加上 Postgres service 和 `make migrateup` | 给测试提供数据库依赖 |
| `039724e` | 在 runner 上安装 `migrate` CLI，密码改成 `secret` | 让 `make migrateup` 真的能跑起来、能连上 Postgres |
| `b7eb3ef` | 把 5432 端口映射到 host | 让 host 上的 step 能访问 service 容器里的 Postgres |


下一节会回到业务侧，开始在 `Store` 之上构建 RESTful HTTP API。
