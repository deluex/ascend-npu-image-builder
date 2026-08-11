#!/usr/bin/env bash
# Build the Ascend NPU image with buildah.
#
# Single source of truth:
#   - versions.conf    : all version numbers
#   - download-all.sh  : all file downloads (idempotent; build runs it first)
#   - build.sh         : buildah invocation only
set -euo pipefail
cd "$(dirname "$0")"

# Load version configuration
source versions.conf

# 1. Make sure all large files are present. download-all.sh is idempotent:
#    it skips files already cached in ./downloads/ and only fetches what's
#    missing, so running it on every build is cheap.
echo ">>> Ensuring downloads are up to date"
./download-all.sh

# 2. Image tag embeds CANN / torch / torch_npu versions
IMAGE="ascend-npu:cann${CANN_VERSION}-torch${TORCH_VERSION}-torch_npu${TORCH_NPU_VERSION}-${SOC}"

echo ">>> building image: ${IMAGE}"
echo ">>>   BASE_IMAGE=${BASE_IMAGE} APT_MIRROR=${APT_MIRROR}"
echo ">>>   CANN=${CANN_VERSION} SOC=${SOC} PYTHON=${PYTHON_VERSION}"
echo ">>>   torch=${TORCH_VERSION} torchvision=${TORCHVISION_VERSION} torch_npu=${TORCH_NPU_VERSION}"
echo ">>>   TORCH_INDEX=${TORCH_INDEX}"

# 3. Proxy handling. Build with --network=host so the build container shares
#    the host network stack: 127.0.0.1 inside the container IS the host's
#    loopback. This is required when the proxy only listens on 127.0.0.1
#    (e.g. a Windows-host proxy reached from WSL2). --http-proxy=true injects
#    the host proxy vars as-is and they just work.
#    NOTE: --network=host only affects the build process, not the final image.
buildah bud --format docker --layers --network=host --http-proxy=true \
    --build-arg BASE_IMAGE="${BASE_IMAGE}" \
    --build-arg APT_MIRROR="${APT_MIRROR}" \
    --build-arg PIP_INDEX="${PIP_INDEX}" \
    --build-arg CANN_VERSION="${CANN_VERSION}" \
    --build-arg SOC="${SOC}" \
    --build-arg PYTHON_VERSION="${PYTHON_VERSION}" \
    --build-arg PYTHON_MM="${PYTHON_MM}" \
    --build-arg TORCH_VERSION="${TORCH_VERSION}" \
    --build-arg TORCHVISION_VERSION="${TORCHVISION_VERSION}" \
    --build-arg TORCH_NPU_VERSION="${TORCH_NPU_VERSION}" \
    --build-arg TORCH_INDEX="${TORCH_INDEX}" \
    -t "${IMAGE}" .

echo ">>> done: ${IMAGE}"
echo ">>> run: ./run.sh  (or see README.md)"
