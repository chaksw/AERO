# syntax=docker/dockerfile:1
#
# aero-dev —— AERO 的主工作台
#
# ============================================================================
# 【定位】C++ 是主工具箱，Python 是原型草稿纸。
#
#   这条定位来自实际工作流：先在 Python 上把融合算法跑通，再在 C++ 里实现。
#   两者放在同一个容器里，是因为这条工作流需要"同一个终端、同一个目录、
#   能直接对比两边输出"：
#
#       uv run python kalman_proto.py                          # 原型
#       g++ -std=c++20 -O2 kalman.cpp -o kalman && ./kalman     # 实现
#       diff <(uv run python kalman_proto.py) <(./kalman)       # 对齐结果
#
#   拆成两个容器反而会让"原型 → 实现 → 对齐结果"这条链路变得别扭。
#
# 【依据】不是拍脑袋，是官方规范：
#
#   1) Dev Container 规范（containers.dev）：
#      "The focus of devcontainer.json is to describe how to enrich A CONTAINER
#       for the purposes of development rather than acting as a multi-container
#       orchestrator format."
#      => 官方推荐的"开发环境"模型就是【一个 primary 容器】。
#
#   2) Docker 官方 best practices 的 "Decouple applications"：
#      "Each container should have only one concern ... Limiting each container
#       to one process is a good rule of thumb, but it's not a hard and fast rule."
#      它举的例子是 web app / database / cache —— 那是【可部署的服务】，
#      不是【交互式工具链】。
#
#   3) 真正该解耦的，本仓库用 ruff 服务做了：
#      - ruff : Astral 官方镜像，Ruff 版本与 Python 环境解绑（见 docker-compose.yml）
#
#      （曾经还有一个 cpp-env 服务，已删除 —— 因为它和本镜像的 C++ 工具链
#        完全重复。删除理由记在 docker-compose.yml 头部，以免以后又想加回来。）
#
# ============================================================================
# 【为什么这里没有 Node / npm / npx】
#
#   曾经有过，后来实测确认不需要，已移除。理由不是"懒得装"，而是：
#
#   * MCP server 由 DSH 在【宿主】上用宿主 PATH 启动，是 DSH 的子进程。
#     证据：@deepseek-ai/dsh-mcp-client 官方最小配置就是
#         command: npx
#         args: ['-y', '@modelcontextprotocol/server-github']
#     裸命令名 => 用宿主 PATH 解析 => 容器里的 Node 永远不会被 MCP 用到。
#   * 宿主本来就有 node（v24.12.0），宿主侧需求已满足。
#   * 于是容器里的 Node 属于 Docker 官方说的 "unnecessary packages"。
#
#   真要用时一行命令，完全不碰本镜像：
#       docker run --rm -it -v "${PWD}\workspace:/w" -w /w \
#         node:24-trixie-slim npx -y <包名>
#
# ============================================================================
# 本镜像内容 = bash/zsh + 核心 CLI + C/C++ 工具链(gcc/g++/gdb/cmake/ninja)
#              + Python 3.13 + uv + Ruff
# ============================================================================


# 基础镜像选 python:3.13-slim-trixie 而不是 debian:trixie-slim：
#   官方 python 镜像已经处理好了解释器、pip、venv、ensurepip。
#
# 注意这里的取舍（说清楚，免得以后困惑）：
#   基础镜像决定了 C++ 编译器来自 Debian 打包的 build-essential => GCC 14.2.0。
#   这是"Python 好装"与"用 gcc 官方镜像的 GCC 15"之间的一次权衡，
#   最终选了前者，因为：
#     1) GCC 14.2 完整支持 C++20，对数值/融合算法完全够用；
#     2) gcc 官方镜像实测 2.19 GB，且继承了 buildpack-deps 的一大堆无关层；
#     3) 关键：将来做生产镜像时，build 阶段也要用 GCC 14.2 才能与
#        Debian trixie 运行时的 libstdc++ 版本对齐（见 DOCKER.md 踩坑记录）。
FROM python:3.13-slim-trixie

LABEL org.opencontainers.image.title="aero-dev" \
      org.opencontainers.image.description="AERO workbench: C/C++ toolchain (gcc/g++/gdb/cmake/ninja), bash/zsh + core CLI, Python 3.13 + uv for prototyping, Ruff" \
      org.opencontainers.image.base.name="docker.io/library/python:3.13-slim-trixie"

# ---------------------------------------------------------------------------
# 系统工具层：shell + 日常 CLI + C/C++ 工具链
#
# 按 Docker 官方建议：多行参数按字母序排列、用 --no-install-recommends、
# 装完删掉 apt 缓存（不删的话包索引会留在镜像层里）。
#
# 说明几个关键项（它们是这个环境存在的理由，不是可选件）：
#   build-essential  gcc / g++ / make —— C++ 主工具箱
#   cmake            构建系统
#   ninja-build      CMake 的现代默认生成器，比 make 快；
#                    将来生产镜像的 build 阶段也用同一个
#   gdb              调试器（配合 compose 里的 SYS_PTRACE 才能下断点）
#   pkg-config       找第三方库（Eigen 之类）时会用到
#
# build-essential 已包含 gcc / g++ / make，不用单独列。
#
# 关于 vim：这里装的是完整的 vim，不是更省空间的 vim-tiny。
# 实测踩到的坑 —— Debian 的 vim-tiny 只提供 `vi` / `vim.tiny`，
# **不会**提供 `vim` 这个命令名。
# 代价：多拉一个 vim-runtime，约 30 MB —— 相对于本镜像的体积可以忽略。
#
# 关于 libstdc++6 / ca-certificates：
#   早先这里有一条单独的 apt 层装它们，理由是给 Node 当运行时库。
#   Node 移除后实测确认：基础镜像已自带 ca-certificates，
#   而 libstdc++6 由 build-essential 依赖链带进来，
#   那条层"0 upgraded, 0 newly installed"—— 装了等于没装，已删除。
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
      bash-completion \
      build-essential \
      cmake \
      curl \
      gdb \
      git \
      jq \
      less \
      ninja-build \
      pkg-config \
      procps \
      ripgrep \
      tree \
      vim \
      zsh \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# uv —— 官方推荐用法：从 Astral 的 distroless 镜像里拷贝二进制
# 依据：https://docs.astral.sh/uv/guides/integration/docker/
#       COPY --from=ghcr.io/astral-sh/uv:<version> /uv /uvx /bin/
#
# 官方同时强调：请钉死具体版本，不要用 :latest。
#
# UV_PYTHON_DOWNLOADS=never ：只用镜像自带的 python3.13，
#   不让 uv 在容器里再偷偷下载一份解释器。
# UV_TOOL_BIN_DIR=/usr/local/bin ：把 uv tool 装出来的可执行文件放到 PATH 上。
# UV_LINK_MODE=copy ：虚拟环境在数据卷上、uv 缓存在容器层，跨文件系统，用 copy。
#
# ⚠️ 这里**故意不设** UV_COMPILE_BYTECODE。
# uv 官方文档把字节码编译定位成**生产镜像**的优化：
#   "Compiling Python source files to bytecode is typically desirable for
#    PRODUCTION images as it tends to improve startup time (at the cost of
#    increased installation time and image size)."
#
# 实测教训（本仓库踩过，已复现两次）：一旦把 UV_COMPILE_BYTECODE=1 写进镜像 ENV，
# 它会**渗进你在容器里敲的每一次 `uv sync` / `uv add`**，然后稳定失败：
#
#   $ docker compose exec aero-dev uv sync
#   error: Failed to bytecode-compile Python file in: .venv/lib/python3.13/site-packages
#     Caused by: Bytecode compilation failed, expected "…/test_scalar_compat.py", received: ""
#
# 对照实验（uv 0.12.13 / 数据卷 ext4）：
#   UV_COMPILE_BYTECODE=1  exit=2（失败）  /  =0  exit=0（成功），各跑两轮稳定。
#
# 结论：环境变量是**镜像级**的，会同时作用于构建期和交互期。
# 只该给生产镜像用的开关，别写进开发镜像的 ENV。
# ---------------------------------------------------------------------------
COPY --from=ghcr.io/astral-sh/uv:0.12.13 /uv /uvx /bin/

ENV UV_LINK_MODE=copy \
    UV_PYTHON_DOWNLOADS=never \
    UV_TOOL_BIN_DIR=/usr/local/bin \
    UV_TOOL_DIR=/opt/uv-tools

# ---------------------------------------------------------------------------
# Ruff —— 用 uv tool 装，版本与 docker-compose.yml 里那个独立 ruff 服务保持一致。
#
# Ruff 服务于"Python 原型"这一半的职责：原型代码也要保持整洁，
# 而且将来把手写 numpy 原型翻译成 C++ 时，干净的 Python 更容易逐行对照。
#
# 对比 Astral 官方给的独立用法（不需要 Dockerfile）：
#   docker run -v .:/io --rm ghcr.io/astral-sh/ruff check
# 那种方式更适合 CI。这里额外装一份，是为了让 VS Code 的 Ruff 扩展
# 和你在终端敲的 `ruff` 都能直接工作。
# ---------------------------------------------------------------------------
RUN --mount=type=cache,target=/root/.cache/uv \
    uv tool install ruff==0.16.7

# ---------------------------------------------------------------------------
# 一些减少"容器里莫名其妙的报错"的收尾设置
# ---------------------------------------------------------------------------

# 绑定挂载进来的 /workspace 属主可能和容器内 uid 不一致，
# git 会拒绝操作并报 "detected dubious ownership"。预先把目录标记为安全。
RUN git config --system --add safe.directory /workspace \
 && git config --system --add safe.directory '*'

# 让 bash-completion 生效（否则 apt 装了也用不上）
RUN printf '\n[ -f /usr/share/bash-completion/bash_completion ] && . /usr/share/bash-completion/bash_completion\n' \
      >> /etc/bash.bashrc

WORKDIR /workspace

# ---------------------------------------------------------------------------
# 关于 USER：这里刻意保持 root，原因有二，且是"开发容器"特有的：
#   1) 本项目在 Windows 上，源码经 Docker Desktop 绑定挂载进 Linux 容器后
#      属主是 root。切到非 root 用户会立刻遇到"文件写不进去"。
#   2) 这是本地开发容器，不是要发布出去的镜像。
# Docker 官方 "If a service can run without privileges, use USER" 针对的是
# 你**交付**的镜像 —— 将来把 C++ 融合算法打包成生产镜像时，那一层必须加 USER。
# ---------------------------------------------------------------------------

# 保持容器常驻，供 docker compose exec / VS Code 接入。
# 依据 Dev Container 规范：用 Compose 时 overrideCommand 默认 false，
# 容器必须自己活着，否则工具一 attach 容器就退出了。
CMD ["sleep", "infinity"]
