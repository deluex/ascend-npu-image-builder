# =============================================================================
# Ascend NPU Docker image (built with buildah)
#
# Contents:
#   1. Ubuntu 24.04 (replaceable via BASE_IMAGE)
#   2. APT mirror replacement (default: Tsinghua) + common tools:
#      ping / nslookup / tmux / pkill / tree / g++
#   3. Python 3.12 (latest patch), compiled from source into /usr/local/python3.12.x
#   4. CANN 9.1.0: Ascend-cann-toolkit + Ascend-cann-{SOC}-ops + Ascend-cann-nnal
#   5. torch (CPU wheel) + torch_npu
#
# C++ development: the pip torch package ships its own headers, shared libs and
# TorchConfig.cmake under site-packages/torch, so no separate libtorch package is
# installed. Point CMAKE_PREFIX_PATH at site-packages/torch (see README) - it is
# also the ABI-matching choice, since torch_npu is built against that same torch.
#
# Version pairing: CANN, torch and torch_npu must be upgraded as a set. All
# versions live in versions.conf (the single source of truth); build.sh reads
# it and injects every value via --build-arg. The Dockerfile holds NO version
# defaults, so it cannot drift out of sync with the download script.
# See README.md ("Version pairing & sources") for the official matrix.
#
# Build: see build.sh (it passes every ARG through to buildah bud).
#
# Notes:
#   - No NPU hardware / driver is required to BUILD this image.
#   - The image does NOT contain the NPU driver (HDK). The driver lives on the
#     host and must be mounted into the container at runtime (see run.sh / README).
# =============================================================================

# ------------------------- Stage 1: build / install -------------------------
# All ARGs have NO defaults; they must be passed via build.sh --build-arg
# (values come from versions.conf). Only BASE_IMAGE is declared before FROM
# because it is referenced in the FROM line.
ARG BASE_IMAGE

FROM ${BASE_IMAGE} AS build

# ---- Build args (all passed via --build-arg from versions.conf) ----
ARG APT_MIRROR
ARG PIP_INDEX
ARG CANN_VERSION
ARG SOC
ARG PYTHON_VERSION
ARG PYTHON_MM
ARG TORCH_VERSION
ARG TORCHVISION_VERSION
ARG TORCH_NPU_VERSION
ARG TORCH_INDEX

ENV PYTHON_HOME=/usr/local/python${PYTHON_VERSION}
ENV PATH=${PYTHON_HOME}/bin:${PATH}
ENV LD_LIBRARY_PATH=${PYTHON_HOME}/lib:${LD_LIBRARY_PATH}

# 1. Replace APT sources. Ubuntu 24.04 uses the deb822 format
#    (/etc/apt/sources.list.d/ubuntu.sources), then install build deps + tools.
#    The driver (HDK) is intentionally NOT installed: it is not needed to
#    build or to install CANN, and at runtime it comes from the host.
RUN sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g" \
        -e "s|http://security.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g" \
        /etc/apt/sources.list.d/ubuntu.sources \
    && rm -f /etc/apt/sources.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        ca-certificates curl wget git vim jq unzip xz-utils \
        build-essential g++ make cmake gfortran patchelf \
        iputils-ping bind9-dnsutils tmux procps psmisc tree \
        libssl-dev zlib1g-dev libncurses-dev libbz2-dev libreadline-dev \
        libsqlite3-dev libffi-dev liblzma-dev libgdbm-dev libnss3-dev libdb-dev \
        libnuma-dev libblas-dev libblas3 pciutils net-tools \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# 2. Python 3.12 latest patch, compiled from source into /usr/local/python3.12.x
#    (altinstall: never touches the system python in /usr/bin)
#    Source tarball is pre-downloaded by download-all.sh into ./downloads/.
COPY ./downloads /downloads
RUN test -f /downloads/Python-${PYTHON_VERSION}.tgz \
        || { echo "ERROR: Python tarball missing. Run ./download-all.sh first."; exit 1; } \
    && cp /downloads/Python-${PYTHON_VERSION}.tgz /tmp/Python.tgz \
    && tar -xf /tmp/Python.tgz -C /tmp \
    && cd /tmp/Python-${PYTHON_VERSION} \
    && mkdir -p ${PYTHON_HOME}/lib \
    && ./configure --enable-shared LDFLAGS="-Wl,-rpath ${PYTHON_HOME}/lib" --prefix=${PYTHON_HOME} \
    && make -j$(nproc) \
    && make altinstall \
    && ln -sf ${PYTHON_HOME}/bin/python3.12 ${PYTHON_HOME}/bin/python3 \
    && ln -sf ${PYTHON_HOME}/bin/python3   ${PYTHON_HOME}/bin/python \
    && ln -sf ${PYTHON_HOME}/bin/pip3.12   ${PYTHON_HOME}/bin/pip3 \
    && ln -sf ${PYTHON_HOME}/bin/pip3      ${PYTHON_HOME}/bin/pip \
    && rm -rf /tmp/Python-* /tmp/Python.tgz

# pip mirror + CANN/torch_npu runtime deps (same list as the official
# cann-container-image project)
RUN pip install --no-cache-dir -i ${PIP_INDEX} --upgrade pip \
    && pip install --no-cache-dir -i ${PIP_INDEX} \
        attrs cython "numpy<2" decorator sympy cffi pyyaml pathlib2 \
        psutil "protobuf==3.20" scipy requests absl-py wheel

# 3. CANN 9.1.0: toolkit + {SOC}-ops + nnal (three .run packages)
#    Packages are pre-downloaded by download-all.sh into ./downloads/.
RUN ARCH=$(case "$(uname -m)" in x86_64) echo x86_64 ;; aarch64) echo aarch64 ;; *) echo unsupported ;; esac) \
    && test "$ARCH" != "unsupported" \
    && for pkg in Ascend-cann-toolkit Ascend-cann-${SOC}-ops Ascend-cann-nnal; do \
         RUN_FILE="${pkg}_${CANN_VERSION}_linux-${ARCH}.run"; \
         test -f "/downloads/${RUN_FILE}" \
           || { echo "ERROR: ${RUN_FILE} missing. Run ./download-all.sh first."; exit 1; }; \
         cp "/downloads/${RUN_FILE}" "/tmp/${pkg}.run"; \
       done

# toolkit
RUN chmod +x /tmp/Ascend-cann-toolkit.run \
    && /tmp/Ascend-cann-toolkit.run --quiet --install --install-for-all \
    && rm -f /tmp/Ascend-cann-toolkit.run

# ops (chosen by SoC; default 910b, e.g. 910 / 310p / 950 are also available)
RUN chmod +x /tmp/Ascend-cann-${SOC}-ops.run \
    && /tmp/Ascend-cann-${SOC}-ops.run --quiet --install --install-for-all \
    && rm -f /tmp/Ascend-cann-${SOC}-ops.run

# nnal (requires the toolkit env vars)
RUN . /usr/local/Ascend/ascend-toolkit/set_env.sh \
    && chmod +x /tmp/Ascend-cann-nnal.run \
    && /tmp/Ascend-cann-nnal.run --quiet --install --install-for-all \
    && rm -f /tmp/Ascend-cann-nnal.run

# 4. torch + torch_npu (CPU torch wheels).
#    Wheels are pre-downloaded by download-all.sh into ./downloads/ and keep
#    their canonical PEP 427 names (pip refuses renamed wheel files).
#    ${PIP_INDEX} resolves torch's own dependencies (pillow, networkx, ...).
RUN PYTHON_CP="cp$(echo ${PYTHON_MM} | tr -d '.')" \
    && ls /downloads/torch-${TORCH_VERSION}*${PYTHON_CP}*.whl >/dev/null 2>&1 \
       || { echo "ERROR: torch wheel missing. Run ./download-all.sh first."; exit 1; } \
    && pip install --no-cache-dir -i ${PIP_INDEX} \
         /downloads/torch-${TORCH_VERSION}*${PYTHON_CP}*.whl \
         /downloads/torchvision-${TORCHVISION_VERSION}*${PYTHON_CP}*.whl \
    && pip install --no-cache-dir -i ${PIP_INDEX} \
         torch-npu==${TORCH_NPU_VERSION} pandas pydantic tzdata \
    && pip3 check

# 5. Trim install leftovers before copying into the runtime stage. Only items
#    that are pure byproducts of the install process and never read at runtime
#    are removed; all functional content (static libs, simulator, debugger,
#    samples, docs, Python test/idlelib/tkinter) is kept.
RUN set -eux; \
    A=/usr/local/Ascend; \
    # per-package install logs (the install.log dirs left by each .run package)
    find "$A" -type d -name 'install.log' -prune -exec rm -rf {} + 2>/dev/null || true; \
    # python bytecode caches (regenerated on demand)
    find "$A" "${PYTHON_HOME}" -type d -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true; \
    du -sh "$A" "${PYTHON_HOME}" 2>/dev/null || true

# ------------------------- Stage 2: runtime image ---------------------------
# ARGs must be re-declared per stage (Docker semantics); values come from
# build.sh --build-arg, which reads versions.conf.
FROM ${BASE_IMAGE}

ARG APT_MIRROR
ARG PIP_INDEX
ARG CANN_VERSION
ARG PYTHON_VERSION
ARG PYTHON_MM

ENV PYTHON_HOME=/usr/local/python${PYTHON_VERSION}
ENV ASCEND_TOOLKIT_HOME=/usr/local/Ascend/cann-${CANN_VERSION}
ENV ASCEND_TOOLKIT_LATEST_HOME=/usr/local/Ascend/ascend-toolkit/latest
ENV ATB_HOME_PATH=/usr/local/Ascend/nnal/atb/latest/atb/cxx_abi_1
ENV ASCEND_AICPU_PATH=${ASCEND_TOOLKIT_HOME}
ENV ASCEND_OPP_PATH=${ASCEND_TOOLKIT_HOME}/opp
ENV TOOLCHAIN_HOME=${ASCEND_TOOLKIT_HOME}/toolkit
ENV ASCEND_HOME_PATH=${ASCEND_TOOLKIT_HOME}
ENV SITE_PACKAGES=${PYTHON_HOME}/lib/python${PYTHON_MM}/site-packages
# The torch entry resolves to the pip package's own TorchConfig.cmake, keeping
# find_package(Torch) ABI-consistent with the torch_npu build.
ENV CMAKE_PREFIX_PATH=${TOOLCHAIN_HOME}/tools/tikicpulib/lib/cmake:${ASCEND_TOOLKIT_HOME}/lib64/cmake:${SITE_PACKAGES}/torch

# Env vars equivalent to sourcing the toolkit set_env.sh (same as official image)
ENV PATH=${ASCEND_TOOLKIT_LATEST_HOME}/bin:${ASCEND_TOOLKIT_LATEST_HOME}/tools/ccec_compiler/bin:${ASCEND_TOOLKIT_LATEST_HOME}/tools/profiler/bin:${ASCEND_TOOLKIT_LATEST_HOME}/tools/ascend_system_advisor/asys:${ASCEND_TOOLKIT_HOME}/bin:${PYTHON_HOME}/bin:${PATH}
ENV PYTHONPATH=${ASCEND_TOOLKIT_LATEST_HOME}/python/site-packages:${ASCEND_TOOLKIT_LATEST_HOME}/opp/built-in/op_impl/ai_core/tbe:${ASCEND_TOOLKIT_HOME}/python/site-packages:${ASCEND_TOOLKIT_HOME}/opp/built-in/op_impl/ai_core/tbe:${PYTHONPATH}
ENV LD_LIBRARY_PATH=/usr/local/Ascend/driver/lib64:/usr/local/Ascend/driver/lib64/common:/usr/local/Ascend/driver/lib64/driver:${ASCEND_TOOLKIT_LATEST_HOME}/lib64:${ASCEND_TOOLKIT_LATEST_HOME}/lib64/plugin/opskernel:${ASCEND_TOOLKIT_LATEST_HOME}/lib64/plugin/nnengine:${ASCEND_TOOLKIT_LATEST_HOME}/opp/built-in/op_impl/ai_core/tbe/op_tiling:${ASCEND_TOOLKIT_LATEST_HOME}/tools/aml/lib64:${ASCEND_TOOLKIT_LATEST_HOME}/tools/aml/lib64/plugin:${ATB_HOME_PATH}/lib:${PYTHON_HOME}/lib:${SITE_PACKAGES}/torch/lib:${SITE_PACKAGES}/torch_npu/lib:${LD_LIBRARY_PATH}

# Common tools (incl. g++, pkill/pskill)
RUN sed -i \
        -e "s|http://archive.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g" \
        -e "s|http://security.ubuntu.com/ubuntu|http://${APT_MIRROR}/ubuntu|g" \
        /etc/apt/sources.list.d/ubuntu.sources \
    && rm -f /etc/apt/sources.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install --no-install-recommends -y \
        ca-certificates curl wget git vim jq unzip xz-utils \
        build-essential g++ make cmake \
        iputils-ping bind9-dnsutils tmux procps psmisc tree \
        libnuma-dev libblas3 pciutils net-tools openssh-client \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/* \
    && ln -sf /usr/bin/pkill /usr/local/bin/pskill

# Copy artifacts from stage 1
COPY --from=build ${PYTHON_HOME} ${PYTHON_HOME}
COPY --from=build /usr/local/Ascend /usr/local/Ascend
COPY --from=build /etc/Ascend /etc/Ascend

# CANN env vars are set entirely via the ENV instructions above (equivalent to
# sourcing each set_env.sh, but baked into the image so every process inherits
# them: docker run, docker exec, non-interactive scripts - no sourcing needed.
# This replaces the prior /etc/profile + ~/.bashrc + ENTRYPOINT approach, which
# was redundant (ENV already covers all shells) and broke signal forwarding
# (bash-as-PID-1 swallowed SIGTERM, so `docker stop` could not exit cleanly).
CMD ["/bin/bash"]
