# AERO Docker 工作台 —— 从零到跑通

> **定位：C++ 是主工具箱，Python 是原型草稿纸。**
>
> 目标：一个容器里备齐 **C/C++ 工具链（gcc/g++/gdb/cmake/ninja）+ shell + Python + Ruff**，
> 用来学习和实践**大气数据融合算法**。Node 已按实测结论移除（见踩坑记录第 1 条）。
>
> 这份文档同时回答你提出的那个方法论问题：**"把不同开发工具分开配置、降低耦合"到底对不对。**

---

## 0. 先回答方法论问题：你的直觉一半对

### 0.1 Docker 官方那条"解耦"，说的不是开发工具

Docker 官方最佳实践里有一节叫 **Decouple applications**，原文是：

> Each container should have only one concern. Decoupling applications into multiple
> containers makes it easier to scale horizontally and reuse containers. For instance,
> a web application stack might consist of three separate containers, each with its own
> unique image, to manage the web application, database, and an in-memory cache, in a
> decoupled manner.
>
> **Limiting each container to one process is a good rule of thumb, but it's not a hard
> and fast rule.** For example, not only can containers be spawned with an init process,
> some programs might spawn additional processes of their own accord. […] Use your best
> judgment to keep containers as clean and modular as possible.
>
> —— <https://docs.docker.com/build/building/best-practices/>

划重点：

1. 它举的例子是 **web app / database / cache** —— 这是**可部署的服务**。
2. 官方自己把"一容器一进程"降级成了 **rule of thumb（经验法则）**，并明确说
   **"not a hard and fast rule"**，让你 **use your best judgment**。
3. 所以这条规则管的是"**部署**时把服务拆开"，**不管**"**开发**时装几个命令行工具"。

### 0.2 官方对"开发环境"的模型，就是一个主容器

Development Containers 规范（VS Code Dev Containers、GitHub Codespaces、JetBrains 共同遵循）
在元数据参考里写得很直白：

> The focus of `devcontainer.json` is to describe how to enrich **a container** for the
> purposes of development **rather than acting as a multi-container orchestrator format**.
> Instead, container orchestrator formats can be referenced when needed to manage multiple
> containers and their lifecycles.
>
> —— <https://containers.dev/implementors/json_reference/>

翻译：`devcontainer.json` 的定位是"**把一个**容器配置成好用的开发环境"；
Compose 那种多容器编排是用来管**真实依赖服务**（数据库、消息队列）的，
不是用来把 `head`、`gcc`、`ruff` 各关一个小黑屋的。

### 0.3 那"拆开"为什么在开发场景下是亏的

| 你以为得到的 | 实际付出的 |
|---|---|
| 工具互不干扰 | 跨语言要反复 `docker compose exec py-env …`，一条链路的操作被切成几段 |
| 版本独立 | 版本确实独立了，但**绑定挂载的 uid/属主要对齐 N 次**，Windows 下尤其疼 |
| 镜像更小 | 基础层（debian/python）被复制 N 份，总磁盘和内存反而更大 |
| 更容易复用 | VS Code / Pylance 只能 attach 一个容器，**跨容器跳转和补全基本残废** |

### 0.4 你的直觉**对**的地方（本仓库就照这个做了）

解耦是有正确位置的，一共三类：

| 场景 | 正确做法 | 本仓库对应 |
|---|---|---|
| **要钉版本的一次性工具** | 直接用厂商官方镜像，连 Dockerfile 都不用写 | `ruff` 服务 → `ghcr.io/astral-sh/ruff:0.16.7` |
| **真实依赖服务** | Compose 一服务一容器 | 将来接数据库 / MQTT / 可视化服务时再加 |
| **要交付的产物** | **多阶段构建**：build 阶段塞满编译器+linter，runtime 只留运行必需品 | 将来把 C++ 融合算法打包成服务时用 |

Ruff 官方文档自己就给出了这种用法：

```bash
docker run -v .:/io --rm ghcr.io/astral-sh/ruff check
docker run -v .:/io --rm ghcr.io/astral-sh/ruff:0.3.0 check
```

—— <https://docs.astral.sh/ruff/installation/>

> ⚠️ **注意表里没有"给某个语言单独拆一个环境"这一类 —— 因为我们试过，然后删掉了。**
>
> 本仓库曾经有一个 `cpp-env`（C++ 专用容器）。实测发现它和主工作台的
> C++ 工具链**逐字节相同**（同一个 Debian 包 `14.2.0-19`），却带来三笔代价：
>
> 1. **要自己维护两个环境的一致性。** 两个容器的 GCC 一度漂到 15.3 vs 14.2，
>    引发了 `GLIBCXX_3.4.34 not found` 的运行期错误。Docker 不会提醒你这件事。
> 2. **命名和事实相反，制造认知负担。** 文件叫 `cpp.Dockerfile`、服务叫 `cpp-env`，
>    会让人以为"C++ 在副容器里、主容器没有 C++"——而事实正好相反。
> 3. 807 MB 的镜像存着一份完全重复的工具链。
>
> 删掉它之后这三个问题一起消失。教训是：**"隔离"本身不构成拆容器的理由，
> 只有当被拆出来的东西有独立生命周期时（比如生产镜像的 build 阶段）才成立。**

**所以最终架构是：1 个主工作台 + 若干"按需调用"的服务，而不是 N 个平级的环境容器。**

---

## 1. 架构：文件职责与关系

> **一句话定位**：C++ 是主工具箱，Python 是原型草稿纸，两者在**同一个**容器里。
>
> 本节按「先建立概念（1.1）→ 再看关系（1.2）→ 再逐个文件（1.3）→ 再看现状与决策
> （1.4–1.7）」的顺序展开。只想快速查命令的话可以直接跳到第 4 节。

### 1.1 先建立心智模型（四个词）

| 概念 | 比方 | 在本项目里 |
|---|---|---|
| **镜像 image** | 一个**封好的工具箱**，只读 | `aero-dev:local`（1.09 GB） |
| **容器 container** | 把工具箱**打开来用**的那一次运行 | 正在跑的 `aero-dev` |
| **服务 service** | "该怎么开箱"的说明书条目 | `aero-dev`、`ruff` |
| **卷 / 绑定挂载** | 把外面的**桌子**接到工具箱旁边 | `workspace/` ↔ `/workspace` |

> 🔑 **镜像里没有你的代码。** 镜像里只有工具；你的资料是容器跑起来那一刻才从 Windows 挂进去的。
> 所以「构建」和「运行」是两件完全不同的事：
>
> - `docker compose build` = 造工具箱（改了 Dockerfile 才需要，一次性）
> - `docker compose up -d` = 开箱用（每次开工）
> - `docker compose exec … bash` = 钻进箱子里敲命令

### 1.2 文件关系图

```
        ┌──────────────────────────────────────────────────────┐
        │  docker-compose.yml        ← 唯一的事实来源            │
        │  "谁要开箱、怎么开、接哪张桌子"                          │
        └───────┬────────────────────────────┬─────────────────┘
                │ build:                     │ image:
                ▼                            ▼
   ┌──────────────────────┐      ┌──────────────────────────┐
   │ docker/              │      │ ghcr.io/astral-sh/       │
   │   dev.Dockerfile     │      │   ruff:0.16.7            │
   │ （仓库里唯一的配方）   │      │ （别人造好的，零构建）     │
   └──────────┬───────────┘      └────────────┬─────────────┘
              │ 造出                           │ 直接用
              ▼                                ▼
   ┌──────────────────────┐      ┌──────────────────────────┐
   │ 镜像 aero-dev:local  │      │ 容器 ruff                │
   │                      │      │ （按需，跑完即走）         │
   └──────────┬───────────┘      └────────────┬─────────────┘
              │ 运行为                          │
              ▼                                │
   ┌──────────────────────┐                    │
   │ 容器 aero-dev        │                    │
   │ （唯一常驻容器）      │                    │
   └──────────┬───────────┘                    │
              │                                │
              └────────── 都挂载 ───────────────┘
                          ▼
              D:\Projects\AERO\workspace\   ← 你的资料（唯一真实来源）
                          │
                          ├── pyproject.toml ← uv / ruff / Pylance 三方共读
                          ├── uv.lock        ← uv sync 自动生成
                          ├── .venv/         ← 例外！在 Docker 卷里，不在 Windows 上
                          └── Docs/          ← 你的 PDF

   .dockerignore ──→ 决定上面那次 build 把哪些文件发给 Docker 引擎
   .devcontainer/devcontainer.json ──→ 只给 VS Code 看，不产生任何东西
   DOCKER.md ──→ 只给人看，运行时不参与

   ── 以下三个属于【宿主侧的版本控制】，容器完全不参与 ──
   .git/          ← 版本库本体
   .gitignore     ← 排除 756 MB 的 PDF/HEIC 参考资料与各类构建产物
   .gitattributes ← 统一 LF 行尾（Windows 宿主 + Linux 容器双环境，避免 CRLF 噪音）
```

### 1.3 逐个文件的职责

每个文件都标了 **【被谁读】** —— 这是理解它们之间关系的关键。

#### `docker-compose.yml` —— 总指挥

**职责**：**唯一的事实来源**。定义两个 service 各用哪个镜像、挂哪个目录、怎么启动。
【被谁读】你敲的 `docker compose` 命令；VS Code（经 devcontainer.json 间接读）。
【它读谁】`docker/dev.Dockerfile` 的路径。

| 关键配置 | 作用 |
|---|---|
| `volumes: ./workspace:/workspace` | Windows 的 `workspace\` 挂进容器 → 两边改文件立刻互相可见 |
| `volumes: aero-venv:/workspace/.venv` | `.venv` 放 Docker 卷而非 Windows（uv 官方要求；Windows 挂载装小文件极慢） |
| `command: ["sleep","infinity"]` | 让容器常驻，否则 VS Code 一接入容器就退出 |
| `cap_add: SYS_PTRACE` | 让 gdb 能下断点（**你原来就有的，我保留**） |
| `profiles: ["tools"]`（ruff） | `up` 时不启动它，用 `run --rm ruff` 显式调用 |

#### `docker/dev.Dockerfile` —— 唯一的配方

**职责**：一份配方，Docker 按它造出 `aero-dev:local`。
【被谁读】`docker compose build`。

| 来源 | 内容 | 对应什么 |
|---|---|---|
| `FROM python:3.13-slim-trixie` | Python 3.13.15 解释器 | Python 那一半 |
| apt 一层 | build-essential、cmake、gdb、ninja-build、pkg-config、git、vim、zsh、ripgrep、jq、tree、curl、less、procps、bash-completion | **C++ 工具链 + shell** |
| `COPY --from=ghcr.io/astral-sh/uv` | uv 0.12.13 二进制 | Python 包管理 |
| `uv tool install` | ruff 0.16.7 | Ruff |

#### `.dockerignore` —— 构建时的黑名单

**职责**：决定 `docker compose build` 时**哪些文件要打包发给引擎**。
【被谁读】每次 build（compose 里所有 service 的 context 都是仓库根目录 `.`）。

为什么在你项目里特别关键：`workspace/Docs` 下是**几十个 GB 级 PDF**。
**实测效果：构建日志里只有 `transferring context: 1.18kB`。**

> 📌 一处**冗余**（诚实说明）：因为 `workspace/` 被整体排除了，里面的
> `.venv/`、`.ruff_cache/`、`node_modules/` 条目目前是多余的。
> 留着是因为**将来做选项 C 时构建上下文会换成 C++ 源码目录**，那时它们才有意义。现在无害。

#### `.devcontainer/devcontainer.json` —— 给 VS Code 的纸条

**职责**：它**不构建、不产生任何镜像**。只是一张纸条，告诉 VS Code：

> "读 `../docker-compose.yml`，连上 `aero-dev`，把 `/workspace` 当工作区打开，
> 装这 10 个扩展、用这些设置。"

【被谁读】只有 VS Code 的 Dev Containers 扩展。
**删掉它，`docker compose` 的一切用法完全不受影响。**

#### `workspace/pyproject.toml` —— Python 项目的真相

**职责**：**一个文件，三个读者**：

| 读者 | 读它干什么 |
|---|---|
| `uv`（容器内） | `uv sync` 按 `dependencies` 装包，生成 `uv.lock` |
| `ruff`（容器内 + 独立服务） | 按 `[tool.ruff]` 决定行长、规则集 |
| Pylance（VS Code） | 知道你的依赖，做补全和跳转 |

#### `DOCKER.md`（本文件）—— 纯文档

**职责**：给人看的。**运行时不参与任何事**，删掉不影响系统。

### 1.4 两个 service 与当前运行状态

| service | 是什么 | 什么时候用 |
|---|---|---|
| **aero-dev** | 主工作台：C/C++ 工具链（gcc/g++/gdb/cmake/ninja）+ Python + uv + Ruff | `docker compose up -d aero-dev` 一次，之后一直开着。**C++ 和 Python 都在这一个里** |
| **ruff** | 官方 Ruff 镜像，跑完即走 | `docker compose run --rm ruff check .` |

实测的当前状态：

| 项 | 值 |
|---|---|
| 常驻容器 | **1 个**：`aero-dev` |
| service 定义 | 2 个：`aero-dev`（默认启动）、`ruff`（profile 服务，按需 run） |
| 镜像 | `aero-dev:local` **1.09 GB** |
| 容器内工具 | `gcc=14.2.0 cmake=3.31.6 gdb=16.3 python=3.13.15 uv=0.12.13 ruff=0.16.7 node=无` |

### 1.5 版本清单（全部已核实存在，且**在容器内实测过**）

| 组件 | 声明 | 实测版本 | 来源 |
|---|---|---|---|
| 基础镜像 | `python:3.13-slim-trixie` | Python 3.13.15 | Docker 官方镜像 |
| **C/C++ 工具链** | Debian 13 的 `build-essential` + apt | **gcc/g++ 14.2.0**（`gcc-14` = `libstdc++6` = `14.2.0-19`） | apt |
| cmake / gdb / ninja | apt | 3.31.6 / 16.3 / 1.12.1 | apt |
| uv | `0.12.13` | uv 0.12.13 | `ghcr.io/astral-sh/uv` |
| Ruff | `0.16.7` | ruff 0.16.7 | `ghcr.io/astral-sh/ruff`（与容器内 uv tool 装的版本一致） |

> 📌 **GCC 为什么是 14.2 而不是最新**：基础镜像决定了 C++ 编译器来自 Debian
> 打包的 `build-essential`（GCC 14.2.0）。取舍已在 `dev.Dockerfile` 顶部写明。
> 关键约束是：**将来做生产镜像时，build 阶段必须也用 GCC 14.2**，
> 才能与 Debian trixie 运行时的 libstdc++ 对齐（原因见踩坑记录 · 第 4 条）。

> 📌 一个容易踩的坑：官方 python 镜像的 tag 顺序是 **`3.13-slim-trixie`**（`-slim-` 在中间），
> 而官方 node 镜像的是 **`24-trixie-slim`**（`-slim` 在末尾）。写反了会 404。

### 1.6 关键决策记录（这套配置为什么长这样）

| 决策 | 结果 | 详述在哪 |
|---|---|---|
| 1 个主工作台 + 1 个按需工具服务，而不是 N 个平级环境容器 | 采纳 | 0.1–0.4 节（含官方原文） |
| Ruff 用 Astral 官方镜像做成独立服务 | 采纳 | 0.4 节 |
| 容器里**不放 Node/npm/npx** | 移除（省 147 MB） | 踩坑记录 · 第 1 条 |
| **删除 `cpp-env`** 这个 C++ 专用容器 | 移除（省 807 MB + 一整套一致性维护） | 0.4 节、`docker-compose.yml` 头部 |
| **项目纳入 git 版本控制** | 采纳（`.gitignore` 挡住 756 MB 参考资料） | 1.7 节 |
| **清理孤儿镜像 + 构建缓存** | 已执行，**实际释放 13.4 GB** | 1.7 节（含一条关于"预估 vs 实际"的教训） |
| 生产镜像推迟到 C++ 代码写出来之后再谈（选项 C） | 挂起 | 第 6 节 |

### 1.7 清理记录，以及尚未完成的事

#### ✅ 已完成：镜像与构建缓存清理

| 对象 | 清理前 | 清理后 |
|---|---|---|
| 镜像 | 6 个 / **6.551 GB** | **2 个 / 1.13 GB** |
| 构建缓存 | **9.158 GB** | **1.138 GB** |

**释放合计 13.4 GB。** 保留下来的两个镜像：

- `aero-dev:local`（1.09 GB）—— 正在使用
- `ghcr.io/astral-sh/ruff:0.16.7`（36 MB）—— **必须保留**：它是按需服务，
  平时没有常驻容器，所以 `docker image prune -a` 会把它当"无用镜像"误删。
  这就是本次全程使用**定向 `docker rmi`** 而不是 `prune -a` 的原因。

> ⚠️ **我预估 8.8 GB，实际 13.4 GB。差在哪？——一个值得记住的教训**
>
> `docker system df` 报的 "Images RECLAIMABLE 3.982 GB" **只统计每个镜像的"独有层"**，
> 它假设共享层会被别的镜像继续引用。但这次四个镜像**是一起删的**，
> 它们共享的那 1.474 GB 也一并释放了。
> 而构建缓存在镜像删除之后，又有约 3.2 GB 从"被引用"变成"无主"。
>
> **结论：`docker system df` 的 RECLAIMABLE 是保守下界，不是准确预测。**
> 它只告诉你"至少能释放多少"，不告诉你"最多能释放多少"。

**之后重建的一次性代价**：约 4 分钟 + 重新下载约 141 MB 的 apt 包。
日常的 `up` / `exec` **完全不受影响**。

#### ⏳ 尚未完成

| 悬着的事 | 说明 |
|---|---|
| **算法代码：一行都还没有** | `workspace/` 里只有 `pyproject.toml`、`uv.lock`、`Docs/`。**没有 `.py`，没有 `.cpp`** |
| **选项 C（生产镜像）** | 等你代码出来再谈。关键约束（build 阶段必须用 GCC 14.2）已查清并写在第 4 条踩坑记录里 |

> 补充：**宿主上的 git 也需要 `safe.directory`。** 本仓库目录属主是
> `BUILTIN\Administrators` 而当前用户不同，git 会报 `detected dubious ownership`。
> 容器里已在 `dev.Dockerfile` 里预防（`git config --system --add safe.directory '*'`），
> 但**宿主**需要单独执行 `git config --global --add safe.directory D:/Projects/AERO`。

### 1.8 ✅ 本机实测通过清单

这份配置不是"写完就交"的，下列每一条都在这台机器上真跑过：

| 验证项 | 命令 | 结果 |
|---|---|---|
| 构建上下文没被 PDF 拖爆 | `docker compose build` | `transferring context: 1.18kB` ✅ |
| 镜像构建成功 | 同上 | `aero-dev:local Built`，exit 0 ✅ |
| bash / vim / zsh | `bash --version` 等 | bash 5.2.37、vim 9.1、zsh ✅ |
| **C/C++ 工具链** | `gcc -dumpfullversion` 等 | gcc/g++ **14.2.0**、**cmake 3.31.6**、**gdb 16.3**、ninja 1.12.1、make 4.4.1、pkg-config 1.8.1 ✅ |
| Python | `python --version` | 3.13.15 ✅ |
| uv | `uv --version` | 0.12.13 ✅ |
| Ruff（容器内） | `ruff --version` | 0.16.7，与 compose 里的镜像 tag 一致 ✅ |
| **Node/npm/npx 已移除** | `command -v node npm npx corepack` | 四个全部不存在 ✅ |
| Python 依赖端到端 | `uv sync --all-groups` | exit 0（49 个包）✅ |
| 科学计算栈可用 | `import numpy, scipy, pandas, matplotlib` | 2.5.3 / 1.18.1 / 3.0.5 / 3.11.2 ✅ |
| **真实数值计算** | 手写一维卡尔曼滤波 4 步递推 | 输出 `[1016.401, 3.62]` ✅ |
| Ruff 真能抓问题 | `ruff check` 故意写的脏文件 | 抓到 E401/I001/F401/W292，exit 1 ✅ |
| 独立 ruff 服务（官方镜像） | `docker compose run --rm ruff check .` | 脏文件 exit 1；清理后 `All checks passed!` exit 0 ✅ |
| Ruff 排除规则真生效 | 往 `Docs/` 放脏 `.py` 探针 | 已被排除 ✅（两个 root 都验） |
| 绑定挂载可读写 | 写入 `/workspace/.write-test` | 成功 ✅ |
| C++20 编译运行 | `g++ -std=c++20 -O2 -g -Wall -Wextra` | 输出 `sum=3017.0` ✅ |
| **gdb 断点可用** | `gdb -ex "break main" -ex run` | 命中 `0x10a0: …/c++/14/bits/allocator.h, line 161` ✅ |
| 镜像体积 | `docker images` | aero-dev **1.09 GB**（移除 Node 前 1.29）✅ |
| devcontainer.json 语法 | 严格 JSON 解析 | OK，10 个扩展，service=`aero-dev` ✅ |
| **删除 cpp-env 后** | `docker compose config` + `up -d --remove-orphans` | 配置 VALID；旧容器已 `Removed`；`docker/` 下只剩 `dev.Dockerfile` ✅ |

---

## 2. 分步操作

### 前置检查

Docker Desktop 必须处于运行状态（本机已确认在跑）。打开 PowerShell：

```powershell
docker version
docker compose version
```

两条都能输出版本号再往下走。

### 第 1 步：构建镜像

```powershell
cd D:\Projects\AERO
docker compose build
```

- 第一次会拉 `python:3.13-slim-trixie`，约 1～2 分钟（看网速）。
- 只有 `aero-dev` 需要构建；`ruff` 用的是官方现成镜像，不需要构建。
- 构建日志里**不应该**出现 `Sending build context of 2GB` 之类的字样 ——
  如果出现，说明 `.dockerignore` 没生效。

### 第 2 步：起主容器

```powershell
docker compose up -d aero-dev
docker compose ps
```

期望看到 `aero-dev` 状态为 `Up`。

### 第 3 步：验证工具链都在

一条命令全查一遍：

```powershell
docker compose exec aero-dev bash -lc @'
echo "=== shell ==="    && bash --version | head -1
echo "=== python ==="   && python --version && command -v python
echo "=== uv ==="       && uv --version
echo "=== ruff ==="     && ruff --version
echo "=== c/c++ ==="    && gcc -dumpfullversion && cmake --version | head -1
echo "=== gdb ==="      && gdb --version | head -1
echo "=== ninja ==="    && ninja --version
echo "=== node（应当不存在）===" && (command -v node || echo "不存在 ✅")
'@
```

期望输出（**这是本机实测值**，不是猜的）：

```
=== shell ===    GNU bash, version 5.2.37(1)-release (x86_64-pc-linux-gnu)
=== python ===   Python 3.13.15
=== uv ===       uv 0.12.13 (x86_64-unknown-linux-musl)
=== ruff ===     ruff 0.16.7
=== c/c++ ===    14.2.0
=== gdb ===      GNU gdb (Debian 16.3-1) 16.3
=== ninja ===    1.12.1
=== node（应当不存在）=== 不存在 ✅
```

> **GCC 14.2.0 就是设计目标，不是"落后"**：它来自 Debian 打包的 `build-essential`，
> 而且是将来生产镜像 build 阶段必须沿用的版本（原因见「踩坑记录 · 第 4 条」）。

### 第 4 步：装 Python 依赖

```powershell
docker compose exec aero-dev bash -lc "cd /workspace && uv sync --all-groups"
```

这会在**命名卷** `aero-venv` 里建出 `/workspace/.venv`。
（为什么不放在 Windows 绑定挂载上？见 `docker-compose.yml` 里的注释：
uv 官方要求 `.venv` 不进绑定挂载，且 Windows 挂载上装小文件极慢。）

验证：

```powershell
docker compose exec aero-dev bash -lc "cd /workspace && uv run python"
```
```py
import numpy, scipy, pandas, matplotlib; 
print('sci stack OK:', numpy.__version__, scipy.__version__)
```

### 第 5 步：用独立 Ruff 服务跑一次静态检查

```powershell
docker compose run --rm ruff check .
docker compose run --rm ruff format --check .
```

想自动修：

```powershell
docker compose run --rm ruff check --fix .
docker compose run --rm ruff format .
```

> 这一步的意义：**同一个 Ruff 版本、零 Python 环境依赖**。
> 将来接 CI，直接写 `docker run ghcr.io/astral-sh/ruff:0.16.7 check .` 就行。

### 第 6 步（可选）：需要 Node 的时候怎么办

镜像里**故意没有** Node（原因见踩坑记录第 1 条）。真要用时，用官方镜像一次性跑，
**完全不碰你的镜像**：

```powershell
# 在项目目录里跑一个 npx 包
docker run --rm -it -v "${PWD}\workspace:/w" -w /w node:24-trixie-slim npx -y <包名>

# 例如
docker run --rm -it -v "${PWD}\workspace:/w" -w /w node:24-trixie-slim node -e "console.log(process.version)"
```

这比"为了迟早要用而常驻 147 MB"更符合 Docker 官方
*"Don't install unnecessary packages"* 的原则。

### 第 7 步：用 VS Code 进去写代码（你选的路径）

1. VS Code 装扩展 **Dev Containers**（`ms-vscode-remote.remote-containers`）。
2. 打开 `D:\Projects\AERO` 文件夹。
3. `Ctrl+Shift+P` → **Dev Containers: Reopen in Container**。
4. VS Code 会读 `.devcontainer/devcontainer.json`，自动构建并 attach 到 `aero-dev`，
   `/workspace` 作为工作区根目录打开。
5. 左下角显示 `Dev Container: AERO Workbench (C++ core, Python prototype)` 即成功。

进去之后应当自动具备：

- Pylance 补全/跳转（解释器 = `/workspace/.venv/bin/python`）
- 保存时 Ruff 格式化
- C++ 智能感知（C++20）
- 终端默认 bash

> 如果你的 VS Code 打不开容器而只想用终端：**完全没问题**。
> `.devcontainer/devcontainer.json` 只是加了一层便利，删掉它不影响
> `docker compose` 的任何用法。

### 第 8 步：收工 —— 「退出」到底退的是什么

到这里环境已经完全跑通了。但在你合上电脑之前，有件事必须先讲清楚：

> **`exit` 不会关掉容器。**

#### 8.1 容器有两种完全不同的"退出"

实测证据（`docker compose top` 的真实输出）：

```
SERVICE   UID   PID   CMD
aero-dev  root  9110  /sbin/docker-init -- sleep infinity    ← init: true 加的 tini
aero-dev  root  9134  sleep infinity                         ← 容器的 PID 1
```

然后在容器里开一个 shell 再退出：

```
[我在容器里] 我的 PID=500
[我在容器里] PID 1 = docker-init
[我在容器里] 现在退出这个 shell...
--- exit 之后 ---
aero-dev | Up About an hour          ← 容器纹丝不动
```

> **关键认知**：`docker compose exec` 不是"进入容器本体"，
> 而是在**已经跑着的容器里新开一个进程**。
> `exit` 只结束你新开的那个进程（PID 500），PID 1（`sleep infinity`）从头到尾没动过。

所以"退出"要分两个层级，别混为一谈：

| 层级 | 你要做的 | 效果 |
|---|---|---|
| **离开 shell** | `exit` 或 `Ctrl+D` | 人走了，**机器还在跑** |
| **停掉容器** | `docker compose stop` / `down` | 机器关了 |

#### 8.2 容器"常驻"是故意的，而且几乎不花钱

**为什么必须常驻**：VS Code 要能随时 attach 进来。Dev Container 规范里，用 Compose 时
`overrideCommand` 默认是 `false` —— **容器必须自己活着**，否则工具一接入它就已经退出了。
这就是 `docker-compose.yml` 里 `command: ["sleep", "infinity"]` 那一行的全部意义。

**常驻贵不贵**（实测）：

| 指标 | 值 |
|---|---|
| CPU | **0.00%** |
| 内存 | **101.7 MiB** / 15.53 GiB（约 0.65%） |

一个 `sleep infinity` 就是挂在那儿什么都不干。
**所以没有"每天用完就关掉"的必要** —— 关机重启时 Docker Desktop 会自己处理。

#### 8.3 完整的停止 / 清理对照表

| 你想做什么 | 命令 / 操作 | 容器 | `.venv` 卷 | 镜像 |
|---|---|---|---|---|
| 离开容器里的 shell | `exit` / `Ctrl+D` | **继续跑** ✅ | 保留 | 保留 |
| 暂停（恢复最快） | `docker compose stop` | 停止 | 保留 | 保留 |
| 恢复 | `docker compose start` 或 `up -d` | 起回来 | 保留 | 保留 |
| 删掉容器（保留数据） | `docker compose down` | **删除** | **保留** ✅ | 保留 |
| 彻底清空（连 `.venv`） | `docker compose down -v` | 删除 | **删除** ⚠️ | 保留 |
| 关掉整个引擎 | 退出 Docker Desktop | 全停 | 保留 | 保留 |
| 关掉 VS Code 窗口 | 直接关 | **自动 stop** | 保留 | 保留 |

`stop` 与 `down` 的区别：`stop` 只是暂停，容器还在，`start` 起来是**秒级**；
`down` 把容器删了，下次 `up` 要**重新创建**。

#### 8.4 ⚠️ 最重要的一条：`down` 之后，容器里的改动会丢

| 位置 | `down` 之后 | 为什么 |
|---|---|---|
| `/workspace/...`（你的代码、Docs） | **完好** ✅ | 绑定挂载，文件真身在 Windows 上 |
| `/workspace/.venv` | **完好** ✅ | 命名卷 |
| `/usr/local/...`、`/opt/...`、`/root/...` | **丢失** ❌ | 容器可写层，随容器一起被删 |

具体会踩到的例子：

- 容器里 `apt install` 装的包 → `down` 后没了
- `uv tool install` 装出来的工具（在 `/opt/uv-tools`）→ 没了
- 容器里 `git config` 写的 `/root/.gitconfig` → 没了
- Shell 历史（`/root/.bash_history`）→ 没了

> **规律：要永久保留的东西，要么放进 `workspace/`（挂载），
> 要么写进 `docker/dev.Dockerfile`（镜像）。这两者之外的一切都是临时的。**

#### 8.5 一个你可能没意识到的自动行为

`devcontainer.json` 里有一行：

```json
"shutdownAction": "stopCompose",
```

意思是：**你关掉 VS Code 窗口时，VS Code 会自动帮你停掉这些容器。**
所以走 VS Code 路径的话，"退出"这件事已经被自动化了 —— 你可能根本没机会手动停。

想让"关了窗口容器也继续跑"，把那行改成 `"shutdownAction": "none"` 即可
（代价是它会一直占着那约 100 MB 内存，直到你手动 `down`）。

---

## 3. 实测踩坑记录（这六条都是真跑出来的，不是抄来的）

这些条目值得单独成节，因为它们同时演示了"为什么必须真跑一遍"和"拆容器的代价在哪"。

### 第 1 条：为一个"迟早要用"的工具常驻 147 MB —— 以及一次装了 0 个包的 apt 层

早先 `aero-dev` 里是有 Node 的（多阶段从 `node:24-trixie-slim` 取出 node/npm/npx，
占 127 MB + 19.7 MB）。当时的理由是"AI agent 迟早要用"。

后来查了 DSH 的源码，这个理由站不住：

`@deepseek-ai/dsh-mcp-client/README.md` 的官方最小配置是 ——

```yaml
- id: mcp-github
  name: '@deepseek-ai/dsh-mcp-client'
  config:
    serverName: github
    transport: stdio
    command: npx                      # ← 裸命令名，不是绝对路径
    args: ['-y', '@modelcontextprotocol/server-github']
```

`command: npx` 说明 **MCP server 是 DSH 在【宿主】上用宿主 PATH 启动的子进程**。
DSH 跑在 Windows 上，所以用的是 Windows 的 npx ——**容器里的 Node 永远不会被 MCP 用到**。

于是它正好落进 Docker 官方 *"Don't install unnecessary packages"* 的范围，已移除。

**顺带发现的第 2 件事**：移除后回看构建日志，

```
ca-certificates is already the newest version (20250419).
libstdc++6 is already the newest version (14.2.0-19).
0 upgraded, 0 newly installed, 0 to remove and 0 not upgraded.
```

原先专门为 Node 加的那条 apt 层（`ca-certificates` + `libstdc++6`）**一个包都没装**
（基础镜像已自带 ca-certificates，libstdc++6 由 build-essential 依赖链带进来），
白花了一次 `apt-get update` 的时间。已删除。

**教训**：镜像里每个包都应该能回答"谁在用它"。答不上来的，就是该删的。

### 第 2 条：把生产镜像的开关写进开发镜像 ENV，会炸

我一开始在 `docker/dev.Dockerfile` 里设了 `UV_COMPILE_BYTECODE=1`。
uv 官方文档把这个选项定位成**生产镜像**的优化
（"typically desirable for **production** images … at the cost of increased installation time"）。
后果是它在容器里稳定炸掉：

```
$ docker compose exec aero-dev uv sync
error: Failed to bytecode-compile Python file in: .venv/lib/python3.13/site-packages
  Caused by: Bytecode compilation failed, expected "…/test_scalar_compat.py", received: ""
```

对照实验（uv 0.12.13，卷为 ext4）：

| `UV_COMPILE_BYTECODE` | 结果 |
|---|---|
| `1` | exit 2（失败），两轮一致 |
| `0` | exit 0（成功），两轮一致 |

**教训**：环境变量是**镜像级**的，会同时作用于构建期和交互期。
只该给生产镜像用的开关，不要写进开发镜像的 `ENV`。
（修法：已从镜像 ENV 中移除，交互期恢复 uv 默认值。）

### 第 3 条：`/workspace/.venv` 是**挂载点**，不能整个删

如果你想"清干净重装"，会撞上：

```
$ rm -rf .venv
rm: cannot remove '.venv': Device or resource busy
```

因为 `.venv` 本身就是 Docker 命名卷的挂载点。
（更糟的是，强行删挂载点会把容器搞死——我实测让容器变成了 `Exited (255)`。）

正确做法二选一：

```bash
# 方案 A：清空内容而不是删目录
find /workspace/.venv -mindepth 1 -maxdepth 1 -exec rm -rf {} +

# 方案 B：交给 uv（推荐）
uv sync --reinstall
```

### 第 4 条：GCC 落差带来了**硬后果**（GLIBCXX）—— 这条留下的教训仍然有效

> 背景：本仓库曾经有两个容器（主工作台 + `cpp-env`）。`cpp-env` 后来因为
> 功能重复被**整个删除**了 —— 但这一条踩坑记录**保留**，因为它揭示的约束
> 在将来做生产镜像（选项 C）时会**原样出现**。

**当时的问题**：`cpp-env` 基于 `gcc:15-trixie`（GCC 15.3.0），
而主工作台的 GCC 来自 Debian 的 `build-essential`（14.2.0）。

真正要命的不是"警告可能不一样"，而是**运行库符号版本**。实测：

| | 旧 `cpp-env`（GCC 15.3.0） | 主工作台（GCC 14.2.0） |
|---|---|---|
| libstdc++ 文件 | `/usr/local/lib64/libstdc++.so.6.0.34` | `/lib/x86_64-linux-gnu/libstdc++.so.6.0.33` |
| 最高版本节点 | **`GLIBCXX_3.4.34`** | **`GLIBCXX_3.4.33`** |
| 只在 3.4.34 才有的符号 | **11 个** | — |

那 11 个符号里有 `std::__sso_string`、`std::format` 的 locale 转换、
`basic_string::_M_construct` 的新重载 —— 都是真实代码很容易碰到的。

**后果**：用 GCC 15 编译、拿到只有 GCC 14 运行库的机器上跑，
一旦用到那 11 个符号之一，就是：

```
version `GLIBCXX_3.4.34' not found
```

**为什么这条记录留着**：因为**生产镜像天然就是"两个环境"** ——
build 阶段一个镜像、runtime 阶段另一个镜像。上面这个陷阱会在那里**原样重现**，
而且更容易踩到（因为 runtime 阶段通常更精简）。

**将来做选项 C 时的三条解法**：

| 解法 | 做法 | 评价 |
|---|---|---|
| **① build 阶段也用 GCC 14.2**（推荐） | build 阶段用 `debian:13-slim` + apt `build-essential`，与 Debian 运行时的 libstdc++ 同源 | 零风险；代价是放弃 GCC 15 的新特性 |
| ② 静态链接运行库 | 加 `-static-libstdc++ -static-libgcc` | 二进制变大（约 1.5 MB），换来不依赖运行时 libstdc++ |
| ③ 把 libstdc++ 一起打包 | COPY GCC 15 的 `.so` 进 runtime + 配 `ld.so.conf` | 最麻烦，不推荐 |

**顺带一条验证方法**（比看版本号可靠）：在两个环境里分别跑

```bash
gdb -q -batch -ex "break main" -ex run /path/to/binary
```

如果打印出的断点文件路径相同（例如都是 `/usr/include/c++/14/…`），
说明两边用的是同一套标准库头文件/库。

**更普适的教训**：**"隔离"本身不构成拆容器的理由。**
只有当被拆出来的东西有**独立生命周期**（比如生产镜像的 build 阶段 —— 它只在构建时存在）
才值得拆。Docker 不会提醒你两个环境的运行库版本已经不一致。


### 第 5 条：Debian 的 `vim-tiny` 不提供 `vim` 命令

我一开始为了省空间装的是 `vim-tiny`。实测：

```
$ command -v vim
（空）            ← vim-tiny 只注册了 vi / vim.tiny / editor / ex / rview / view
$ command -v vi
/usr/bin/vi
```

后果是：你在容器里敲 `vim` 会得到 `command not found`，而这在一个明确支持
"不开 VS Code、直接终端进容器"的环境里是很烦人的割伤。
已改成安装完整的 `vim`（代价约 +30 MB，相对本镜像 1.4 GB 可忽略）。

### 第 6 条：Ruff 的 `extend-exclude` 路径写错了，而且**不报错**

我一开始在 `workspace/pyproject.toml` 里写的是：

```toml
extend-exclude = [".venv", "workspace/Docs"]
```

看起来完全合理（仓库里确实是 `workspace/Docs`），但它**静默失效**。
我往 `workspace/Docs/` 放了个故意写脏的 `.py` 探针来测，结果 ruff 照样把它抓出来了。

逐个候选模式实测（ruff 0.16.7）：

| `extend-exclude` 值 | 探针是否被排除 |
|---|---|
| `"workspace/Docs"` | 未排除 ❌ |
| `"Docs"` | 已排除 ✅ |
| `"**/Docs"` | 已排除 ✅ |
| `"Docs/**"` | 已排除 ✅ |
| `"/workspace/Docs"` | 已排除 ✅ |

**规律**：模式是相对于**项目根**（`pyproject.toml` 所在目录）匹配的，不是相对于仓库根。
而 `"Docs"` 恰好在本仓库的两种运行方式下都成立：

- `aero-dev` 里项目根 = `/workspace`，Docs 在 `/workspace/Docs` ✅
- `ruff` 服务里项目根 = `/io`，Docs 在 `/io/Docs` ✅

已改成 `[".venv", "Docs"]`，并在两个 root 下都用真实配置复验通过。
**教训**：排除类配置几乎不会报错，只会"安静地不生效"——必须用探针文件验证。

---

## 4. 日常命令速查

```powershell
# 起 / 停
docker compose up -d aero-dev              # 起主容器
docker compose stop                        # 停（保留容器和卷），start 可秒级恢复
docker compose down                        # 删容器（保留 aero-venv 卷）
docker compose down -v                     # 连 aero-venv 卷一起删 ← 会丢 .venv
#   ⚠️ 这三种"退出"的区别、以及 down 会丢掉哪些改动，
#      详见 §2「第 8 步：收工」——那里有实测证据和完整对照表。

# 进容器
docker compose exec aero-dev bash          # 推荐：在主容器里开交互 shell
docker compose exec -u root aero-dev bash  # （当前就是 root，加不加都一样）

# 在容器里跑一次性命令
docker compose exec aero-dev bash -lc "uv run python scripts/xxx.py"

# Ruff（独立服务，零环境依赖）
docker compose run --rm ruff check .
docker compose run --rm ruff format .

# C++ 编译与调试 —— 就在主工作台里，不需要换容器
docker compose exec aero-dev bash
#   容器内（CMake + Ninja）：
#   cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build
#   或者不用 CMake：
#   g++ -std=c++20 -O2 -g -Wall -Wextra main.cpp -o main && ./main
#   调试（需要 compose 里的 SYS_PTRACE）：
#   gdb -q ./main
#
#   Python 原型 → C++ 实现 的对比也在同一个终端里：
#   uv run python kalman_proto.py > py.txt && ./main > cpp.txt && diff py.txt cpp.txt

# 需要 Node / npx 时（镜像里没有，用官方镜像一次性跑）
docker run --rm -it -v "${PWD}\workspace:/w" -w /w node:24-trixie-slim npx -y <包名>

# 重建（改了 Dockerfile 之后）
docker compose build --pull --no-cache
docker compose up -d --force-recreate
```

`--pull` 和 `--no-cache` 的区别（官方文档明确区分）：

- `--pull`：去仓库检查基础镜像有没有新版本
- `--no-cache`：不复用构建缓存，所有步骤重跑
- 两个一起用 = 基础镜像最新 + 依赖最新，**建议每隔几周跑一次**

---

## 5. 排错

| 症状 | 原因 | 处理 |
|---|---|---|
| `docker compose build` 卡在 `Sending build context` | `.dockerignore` 没生效 | 确认文件名是 `.dockerignore`（前面有点），且内容含 `workspace/` |
| 找不到 `node` / `npm` / `npx` | **这是设计如此**，不是坏了 | 镜像里故意没有 Node；需要时用 `docker run … node:24-trixie-slim npx …`（见第 6 步） |
| `uv sync` 报 `Failed to bytecode-compile Python file` | 镜像 ENV 里设了 `UV_COMPILE_BYTECODE=1` | 从 `dev.Dockerfile` 的 `ENV` 里删掉（见踩坑记录第 2 条） |
| `rm -rf .venv` 报 `Device or resource busy` | `.venv` 是卷的挂载点，不能删目录本身 | `uv sync --reinstall`，或 `find .venv -mindepth 1 -maxdepth 1 -exec rm -rf {} +`（见踩坑记录第 3 条） |
| `version 'GLIBCXX_3.4.34' not found` | 用 GCC 15 编译、拿到 GCC 14 运行库的机器上跑 | 本仓库已统一在 GCC 14.2；做生产镜像时注意 build 与 runtime 必须同源，见踩坑记录第 4 条 |
| 容器起来就退出 | `command` 被改掉了 | 必须是 `["sleep", "infinity"]`；用 Compose 时 devcontainer 的 `overrideCommand` 默认 false |
| gdb 断点无效 | 缺 ptrace 权限 | 确认 compose 里有 `cap_add: [SYS_PTRACE]` 与 `seccomp=unconfined` |
| `uv sync` 很慢 / 写 `.venv` 报错 | `.venv` 落在 Windows 绑定挂载上了 | 确认 compose 里有 `- aero-venv:/workspace/.venv` |
| VS Code 里 Python 找不到解释器 | 还没跑 `uv sync` | 容器内执行 `cd /workspace && uv sync --all-groups` |
| `vim: command not found` | Debian 的 `vim-tiny` 只提供 `vi`，不提供 `vim` | 已改为安装完整的 `vim`（见踩坑记录第 5 条） |
| git 报 `detected dubious ownership` | 绑定挂载属主不一致 | 已在镜像里配置 `safe.directory`，重建即可 |
| `docker compose exec` 报 HTTP 500 | 容器已经死了（如删挂载点导致 `Exited 255`） | `docker compose ps -a` 看状态，`docker compose up -d aero-dev` 拉起来 |

查看日志：

```powershell
docker compose logs -f aero-dev
docker compose exec aero-dev bash -lc "df -h /workspace && ls -la /workspace"
```

---

## 6. 下一步：开始大气数据融合的实践

环境通了之后，建议的推进顺序（从最小可验证单元开始）：

1. **Python 原型（草稿纸）**：在 `workspace/scripts/` 下先跑通一个纯 Python 的一维卡尔曼滤波。
   状态 = `[高度, 升降速度]`，观测量 = `[气压高度, 垂直加速度]`。
   `filterpy` / `pykalman` 这类老库对新版 Python 支持不稳，**建议直接用 numpy 手写** ——
   30 行左右，而且手写一遍才真正理解 `P`、`Q`、`R`、`K` 各自在干什么。
   **这份理解正是把它翻译成 C++ 的前提。**
2. **对照仓库里的资料验证**：`workspace/Docs/ADS/` 下有
   《基于模糊自适应卡尔曼滤波的大气数据辅助姿态算法》《飞行器飞行大气数据传感技术发展现状与展望》，
   以及 ARINC 429 相关文献 —— 先用算法把文献里的场景复现出来。
3. **C++ 实现（主工具箱）**：在 `workspace/cpp/` 下建 CMake 工程，把原型翻译过去：
   ```bash
   cmake -S . -B build -G Ninja -DCMAKE_BUILD_TYPE=Release && cmake --build build
   ```
   数值选项建议先固定 `-O2`，**不要**开 `-ffast-math`（它会重排浮点运算、
   假设没有 NaN/Inf，对协方差和归一化可能产生静默错误）。
4. **交叉验证**：同一组输入，Python 原型跑一遍、C++ 跑一遍，**diff 两边输出**。
   这一步就是"原型 → 实现"流程的额外红利 —— 你有了一个独立实现的参照物，
   而不是"我说它对它就对"。也是将来生产镜像的验收标准。
5. **多源融合**：把 `Q`/`R` 的整定过程数据化，比较集中式卡尔曼 vs 联邦滤波。
6. **交付形态（选项 C，等代码出来再谈）**：用**多阶段构建**打包成只含运行必需品的镜像。
   关键约束已经查清：**build 阶段必须用 GCC 14.2**，否则会撞上 GLIBCXX 版本问题
   （见踩坑记录第 4 条）；非 root 用户用 distroless 的 `:nonroot`。

---

## 7. 官方资料来源（本文所有结论的出处）

**Docker**
- Building best practices（多阶段构建 / 钉版本 / .dockerignore / Decouple applications / apt-get / USER）
  <https://docs.docker.com/build/building/best-practices/>
- Why use Compose?（Compose 的定位：开发环境、自动化测试、单机部署）
  <https://docs.docker.com/compose/intro/features-uses/>
- Multi-container applications（官方"多容器"教程）
  <https://docs.docker.com/get-started/docker-concepts/running-containers/multi-container-applications/>

**Development Containers 规范**
- devcontainer.json 元数据参考（"rather than acting as a multi-container orchestrator format"、
  `capAdd: SYS_PTRACE`、`init`、Compose 场景下的 `overrideCommand` 默认值）
  <https://containers.dev/implementors/json_reference/>
- 支持工具列表（VS Code / Codespaces / JetBrains…）
  <https://containers.dev/supporting>

**Ruff / uv（Astral 官方）**
- Installing Ruff（含官方 Docker 镜像用法 `ghcr.io/astral-sh/ruff`）
  <https://docs.astral.sh/ruff/installation/>
- Using uv in Docker（`COPY --from=ghcr.io/astral-sh/uv:<pin> /uv /uvx /bin/`、
  `.venv` 不进绑定挂载、cache mount、`UV_PROJECT_ENVIRONMENT`）
  <https://docs.astral.sh/uv/guides/integration/docker/>

**镜像 tag/版本的可验证来源**
- Docker Hub 官方镜像 tag 列表 API：`https://hub.docker.com/v2/repositories/library/<image>/tags`
- Rust 侧最新版本：`https://api.github.com/repos/astral-sh/ruff/releases/latest`、
  `https://api.github.com/repos/astral-sh/uv/releases/latest`
