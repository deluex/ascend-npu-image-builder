# 昇腾 NPU Docker 镜像 (buildah 构建)

基于 Ubuntu 的自建镜像，包含常用运维工具、Python、CANN、torch 与 torch_npu。所有版本号集中管理在 [`versions.conf`](versions.conf)，修改版本只需改该文件。

---

## 快速开始

### 脚本入口

| 脚本 | 用途 | 说明 |
|---|---|---|
| **`./download-all.sh`** | 预下载所有大文件 | **推荐首次运行**：下载 Python 源码、CANN 三包、torch/torchvision wheels 到本地缓存（支持断点续传） |
| **`./build.sh`** | 构建镜像 | **主入口**：调用 buildah 构建镜像，优先使用本地缓存文件，缺失时在线下载 |
| `./run.sh` | 运行容器 | 自动挂载 NPU 设备与宿主机驱动（需宿主机装好 HDK 驱动） |
| `./verify.sh` | 冒烟测试 | 在容器内验证 Python / 工具 / CANN / torch / torch_npu |

### 构建步骤（推荐流程）

```bash
# 1. 预下载所有大文件到本地缓存（首次构建或换机器时运行，约 4.5 GB）
#    支持断点续传，可重复执行，已下载的文件会跳过
./download-all.sh

# 2. 构建镜像（约 40 分钟，主要耗在编译 Python 和精简 CANN）
#    会优先使用 ./downloads/ 中的缓存文件
./build.sh

# 3. 运行容器（需宿主机装好 NPU 驱动）
./run.sh

# 4. 容器内验证
/root/verify.sh
```

### 自定义构建

```bash
# 更换 SoC（如 310P 推理卡）
SOC=310p ./download-all.sh  # 先下载对应 SoC 的 ops 包
SOC=310p ./build.sh

# 更换镜像源
APT_MIRROR=mirrors.aliyun.com PIP_INDEX=https://mirrors.aliyun.com/pypi/simple ./build.sh

# 更换版本（需先查配套表，见下文"版本配套"章节）
CANN_VERSION=9.0.0 TORCH_VERSION=2.10.0 TORCH_NPU_VERSION=2.10.0.post2 ./build.sh
```

---

## 构建产物管理（清理 / 导出 / 压缩）

构建完成后镜像位于 buildah 本地仓库，标签格式为
`localhost/ascend-npu:cann${CANN_VERSION}-torch${TORCH_VERSION}-torch_npu${TORCH_NPU_VERSION}-${SOC}`（版本号来自 `versions.conf`）。

### 清理构建缓存

多次构建会在 buildah storage 累积大量无标签中间层（dangling images），可定期清理：

```bash
# 查看当前占用
du -sh /var/lib/containers/storage

# 删除所有无标签的中间层（不影响有标签的镜像）
buildah rmi --prune

# 删除指定镜像
buildah rmi localhost/ascend-npu:<tag>   # tag 见 build.sh 输出
```

> 清理后再构建会重新执行所有层（缓存已清），但 `downloads/` 中的文件不受影响。

### 导出镜像

`buildah push docker-archive:` 默认**不压缩**，输出的 tar 文件与镜像体积相当。

```bash
# 导出为 Docker 格式（未压缩，兼容 docker load / podman load）
buildah push localhost/ascend-npu:<tag> docker-archive:ascend-npu.tar

# 导出为 OCI 格式（内部层已 gzip，体积略小，podman load 支持）
buildah push localhost/ascend-npu:<tag> oci-archive:ascend-npu-oci.tar
```

### 导出并压缩（推荐）

边导出边压缩，避免产生中间未压缩大文件，直接输出压缩包（体积约为镜像的 1/3）：

```bash
# pigz（并行 gzip，速度快，CPU 占用高）
buildah push localhost/ascend-npu:<tag> docker-archive:/dev/stdout | pigz -9 > ascend-npu.tar.gz

# xz（压缩率更高，但速度慢，适合长期归档）
buildah push localhost/ascend-npu:<tag> docker-archive:/dev/stdout | xz -9 -T0 > ascend-npu.tar.xz

# 如果没有 pigz，用单线程 gzip
buildah push localhost/ascend-npu:<tag> docker-archive:/dev/stdout | gzip -9 > ascend-npu.tar.gz
```

### 导入镜像

```bash
# gunzip + podman load（推荐，自动识别格式）
gunzip -c ascend-npu.tar.gz | podman load

# docker 环境导入
gunzip -c ascend-npu.tar.gz | docker load

# 或直接导入未压缩的 tar
podman load < ascend-npu.tar
```

### 完整工作流示例

```bash
# 1. 构建（自动按需下载 + buildah 构建）
./build.sh

# 2. 验证镜像
./run.sh

# 3. 导出并压缩到单文件（tag 见 build.sh 输出）
buildah push localhost/ascend-npu:<tag> docker-archive:/dev/stdout | pigz -9 > ascend-npu.tar.gz

# 4. 清理本机构建缓存（可选）
buildah rmi --prune

# 5. 传输到目标机器并导入
scp ascend-npu.tar.gz target-host:~/
ssh target-host 'gunzip -c ascend-npu.tar.gz | podman load'
```

---

## 版本配套与来源（修改版本时必读）

### 版本配置

具体版本号见 [`versions.conf`](versions.conf)。主要组件：Ubuntu 基础镜像、Python、CANN（toolkit + `{SOC}`-ops + nnal 三个 `.run` 包）、torch（CPU wheel）、torchvision、torch_npu。

**配套关系**：CANN、torch、torch_npu 三者必须配套，修改时需整体升级，参考[昇腾社区配套表](https://www.hiascend.com/developer/software/ai-frameworks/pytorch/download)。

### CANN 三包结构

- **Ascend-cann-toolkit**：核心工具链（ATC 编译器、毕昇编译器、aicpu 算子库）
- **Ascend-cann-{SOC}-ops**：按芯片型号编译的算子包（运行必需）
- **Ascend-cann-nnal**：神经网络加速库（atb + asdsip/SIP 子模块）

### 支持的 SoC 型号（通过 `SOC` 参数切换）

- `910b`（默认）：Atlas 800T A2 / 300I Duo
- `310p`：Atlas 300I Pro（推理卡）
- `910`：Atlas 800 训练服务器（A1 系列）
- `950`：新一代训练芯片
- `a3`：Atlas 900 A3

**驱动要求**：宿主机需安装与 CANN 兼容的 NPU 驱动（HDK），版本对照表见[昇腾社区配套表](https://www.hiascend.com/developer/download/community/result)。

### 镜像清理说明

精简策略保守——只删除安装过程的纯副产物，保留全部功能内容（静态库、模拟器、调试器、samples、文档、Python test/idlelib/tkinter 均保留），确保镜像可用于算子开发、调试和文档查阅。

构建时只清理以下两类安装副产物：

| 清理项 | 路径 | 说明 |
|---|---|---|
| 安装日志 | `/usr/local/Ascend/**/install.log` | CANN `.run` 包安装时生成的日志目录 |
| 字节码缓存 | `/usr/local/Ascend/**/__pycache__`、`${PYTHON_HOME}/**/__pycache__` | Python 字节码缓存，运行时自动重建 |

---

## 文件说明

| 文件 | 用途 |
|---|---|
| **`versions.conf`** | **统一版本配置文件**：所有脚本和 Dockerfile 读取版本号，修改版本只需改这一处 |
| `Dockerfile` | 镜像定义（两阶段：编译/安装 → 运行时） |
| `build.sh` | buildah 构建脚本（先调下载、再构建，无环境变量覆盖） |
| `download-all.sh` | 统一预下载脚本：下载 Python 源码 + CANN 三包 + torch wheels 到 `downloads/` |
| `run.sh` | 容器运行脚本（自动挂载 NPU 设备与宿主机驱动） |
| `verify.sh` | 镜像内冒烟测试 |
| `downloads/` | 本地缓存目录（所有大文件统一存放，`.gitignore` 已排除） |

---

### 换版本时的检查清单

1. **改 `versions.conf`**：所有版本号集中在此，改一处即可生效到下载脚本、Dockerfile、镜像标签。
2. **查配套表**：CANN / torch / torch_npu 三者严格配套，先查
   [昇腾社区配套表](https://www.hiascend.com/developer/download/community/result) 或
   pytorch 仓库 release notes，锁定三元组。
3. **确认 Python 兼容**：torch_npu 对 Python 版本有要求（3.10~3.13 常见），PyPI 上确认
   对应 cp 版本的 wheel 存在。
4. **确认下载地址**：CANN 包需带 `Referer: https://www.hiascend.com/` 请求头；
   torch CPU wheel 国内镜像站均不含，只能从 `download.pytorch.org` 下载（`download-all.sh` 已处理）。
5. **注意安装依赖的匹配**：换 CANN 大版本时，与官方 `cann-container-image` 对应版本目录里的
   Dockerfile 核对 CANN python 依赖清单（如 `protobuf==3.20` 等）。

### C++ 接口（不装独立 libtorch）

pip 版 torch wheel 已自带完整 C++ 部分，**不再安装独立 libtorch 包**（省约 181 MB，且避免 ABI 冲突）：

- 头文件：`{torch}/include/`（含 `torch/torch.h`、ATen、c10）
- 动态库：`{torch}/lib/`（`libtorch.so`、`libtorch_cpu.so`、`libc10.so` 等）
- CMake 包：`{torch}/share/cmake/Torch/TorchConfig.cmake` → `find_package(Torch)` 直接可用

其中 `{torch}` = `python3 -c 'import torch,os;print(os.path.dirname(torch.__file__))'`。
镜像已把它写进 `ENV CMAKE_PREFIX_PATH` 与 `LD_LIBRARY_PATH`，`cmake` 与运行时都能直接找到。

⚠️ 不要另装官方 libtorch 预编译包：`libtorch-shared-with-deps` 是 **pre-cxx11 ABI**
（`_GLIBCXX_USE_CXX11_ABI=0`），而 `torch_npu` 的 so 按 cxx11 ABI 编译，两者混用会在链接
或运行期崩溃；`cxx11-abi` 变体在该版本未发布（404）。pip wheel 自带的那份 ABI 与 torch_npu 一致。

**torch_npu 的 C++ 侧**：wheel 里已含 `torch_npu/lib/libtorch_npu.so` 与 `torch_npu/include/`，
但**不含** `Torch_npuConfig.cmake`，所以 `find_package(Torch_npu)` 不可用，需在 CMake 里手写：

```cmake
find_package(Torch REQUIRED)                 # 走 pip torch 自带的 TorchConfig.cmake
# TORCH_NPU_ROOT = python3 -c 'import torch_npu,os;print(os.path.dirname(torch_npu.__file__))'
target_include_directories(app PRIVATE ${TORCH_NPU_ROOT}/include)
target_link_libraries(app PRIVATE ${TORCH_LIBRARIES} ${TORCH_NPU_ROOT}/lib/libtorch_npu.so)
```
  注意：完整编译 torch_npu C++ 库约需 1 小时，且需网络；Python 侧 torch_npu 不受影响。
  该脚本按官方流程编写，本仓库构建环境未完整跑通编译（无网络/时长限制），首次使用如报错请结合官方文档调整。

### 安装后校验

- Dockerfile 在 torch/torch_npu 安装步骤末尾执行 **`pip3 check`**，任何 python 依赖缺失/冲突都会导致构建失败（而非镜像带病产出）。
- 运行时可跑 `verify.sh` 冒烟测试，其中 torch_npu 导入与 npu-smi 需要宿主机驱动（无 NPU 环境会提示跳过）。

---

## 运行（宿主机需有 NPU + 驱动）

镜像内**不含驱动 (HDK)**，容器通过挂载使用宿主机驱动（昇腾官方做法）。
无 NPU 的机器也能构建本镜像，只是容器内无法访问 NPU。

```bash
# 方式 A: 已安装 Ascend Docker Runtime
docker run -it --rm --runtime ascend --device all \
    --ipc=host --network=host \
    -v /usr/local/Ascend/driver:/usr/local/Ascend/driver \
    localhost/ascend-npu:<tag>

# 方式 B: 手动挂载 (本仓库 run.sh 即此方式, 自动探测设备)
./run.sh
```

在容器内验证：

```bash
npu-smi info                 # 应能看到 NPU 卡
python3 -c "import torch, torch_npu; print(torch.npu.is_available())"
# 或运行仓库内置冒烟测试 (无 NPU 也能跑, 相关步骤会提示跳过)
/root/verify.sh
```

## 镜像内容说明

1. **apt 源替换**: Ubuntu 24.04 使用 deb822 格式 (`/etc/apt/sources.list.d/ubuntu.sources`),
   脚本将 archive/security 两个源一并替换为指定镜像。
2. **常用工具**: `ping` (iputils-ping), `nslookup` (bind9-dnsutils), `tmux`, `pkill` (procps),
   `pskill` (已建软链 → pkill, Linux 下无原生 pskill), `tree`, `g++` (build-essential), 另有
   git / vim / jq / curl / wget / cmake / make 等。
3. **Python**: 源码编译 (华为云镜像 tarball), 安装到 `/usr/local/python${PYTHON_VERSION}`
   (不覆盖系统 `/usr/bin/python3`), `PATH` 中 `python`/`pip` 均指向该版本。已安装
   CANN/torch_npu 运行依赖 (numpy<2, sympy, decorator, cffi, protobuf==3.20 等, 清单与官方镜像一致)。
4. **CANN**: 按官方 `.run --install --install-for-all` 安装 toolkit / ops / nnal 三个包。
   从 toolkit 开始安装，**不装 HDK/驱动**（构建和安装都不需要驱动，运行时才由宿主机提供）。
   CANN 环境变量全部通过 `ENV` 指令内建到镜像（等效于 source 各 `set_env.sh`），
   所有进程（docker run / exec / 非交互脚本）直接继承，无需手动 source。
5. **torch + torch_npu**: CPU 版 torch (避免下载 2.5GB 的 CUDA 包), torch_npu 从 PyPI 安装。
6. **清理**: 在 stage 1 拷贝前删除 CANN 安装日志目录和 `__pycache__` 字节码缓存（运行时自动重建）。
   保留静态库、模拟器、调试器、samples、文档等全部功能内容。放在 stage 1 做是关键：
   若在 stage 2 删, 文件仍留在上层里, 镜像不会变小。

## 可移植性: 换机器 / 换架构 / 换芯片

**这套文件是通用的, 产出的镜像绑定 arch + SoC。**

| 维度 | 文件是否通用 | 镜像能否直接拷 |
|---|---|---|
| CPU 架构 (x86_64 / aarch64) | 通用, `uname -m` 自动判断 | **不能**, 需在目标 arch 重新构建 |
| SoC 型号 (910b / 910 / 310p / 950) | 通用, `SOC` 参数控制 | **不能**, ops 包按芯片编译 |
| 宿主 OS 发行版 | 通用, 容器自带 userspace | 能, 只要有 NPU 驱动 |
| 宿主内核版本 | — | 能, 驱动在宿主侧 |

拷到新机器前确认三件事:

1. **arch 匹配**: 鲲鹏/飞腾 (aarch64) 上直接 `./build.sh` 即可, Dockerfile 会自动取
   `aarch64` 的 CANN 包和 wheel。已构建好的 amd64 镜像**不能**在 aarch64 上运行。
2. **宿主装好 NPU 驱动 (HDK) 且版本兼容 CANN**: 镜像故意不含驱动 (内核态组件, 必须与宿主
   内核匹配), 运行时由 `run.sh` 挂载宿主的 `/usr/local/Ascend/driver` 与 `/dev/davinci*`。
   目标机 `npu-smi info` 查驱动版本, 对照官网 CANN-HDK 配套表。
3. **SoC 匹配**: 默认 `910b` (Atlas 800T A2 / 300I Duo)。推理卡用
   `SOC=310p ./build.sh`, 其他型号同理。

跨 arch 构建建议在目标机上直接跑, 不要用 qemu 模拟 (CANN 这个体量会慢到不可用)。

## 常见问题

- **Ubuntu 版本支持**: 昇腾官方容器镜像主打 ubuntu 22.04/openeuler24.03。当前 CANN 在 24.04 上
  安装运行无问题 (glibc 满足要求)；如遇官方严格校验环境，可在 `versions.conf` 改 `BASE_IMAGE`。
- **运行时报 `libascend_hal.so` / `libatb.so` not found**: 确认镜像内 ENV 已正确设置
  （本镜像已通过 ENV 内建，无需手动 source）。
- **`import torch_npu` 报 driver 相关错误**: 确认容器挂载了宿主机 `/usr/local/Ascend/driver` 与
  `/dev/davinci*` 设备 (见 run.sh)。无 NPU 环境 `import torch_npu` 失败属于正常。
- **构建报 404**: 换版本后 URL 变了, 按上文"关键下载地址模式"逐个 `curl -IL` 探测;
  CANN 包务必带 `Referer: https://www.hiascend.com/` 请求头。
- **换 torch 大版本 (如 2.10)**: 同步改 `TORCH_VERSION` / `TORCHVISION_VERSION` / `TORCH_NPU_VERSION`
  三者为配套组合, 并核对 CANN 版本。
- **构建很慢**: 主要耗时在下载 CANN 三个包 (toolkit、ops、nnal 合计数 GB) 与编译 Python。

## 参考链接

- CANN 安装文档 (独立安装): https://www.hiascend.com/document/detail/zh/CANNCommunityEdition/latest/softwareinst/instg/instg_0008.html
- 昇腾社区下载中心/配套表: https://www.hiascend.com/developer/download
- 官方容器镜像仓库 (Dockerfile 参考): https://github.com/Ascend/cann-container-image
- torch_npu 仓库 (版本配套表/安装指南/发布说明): https://github.com/Ascend/pytorch
- torch_npu 安装指南: https://ascend.github.io/docs/sources/pytorch/install.html
- CANN 社区下载: https://www.hiascend.com/cann/download
