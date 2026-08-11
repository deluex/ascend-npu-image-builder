#!/usr/bin/env bash
# Pre-download all large files (Python source, CANN packages, torch wheels)
# to ./downloads/ for offline or faster builds.
#
# Download tool: prefers wget, automatically falls back to curl if wget fails
# (some proxy servers reject wget on certain hosts, e.g. download.pytorch.org).
# Supports resuming interrupted downloads (-c / -C -).
set -euo pipefail
cd "$(dirname "$0")"

# Load version configuration (single source of truth: versions.conf)
if [ -f versions.conf ]; then
    source versions.conf
else
    echo "ERROR: versions.conf not found"
    exit 1
fi

ARCH=$(uname -m)
case "$ARCH" in
    x86_64|aarch64) ;;
    *) echo "Unsupported arch: $ARCH"; exit 1 ;;
esac

# Prefer wget, fall back to curl
if command -v wget >/dev/null 2>&1; then
    DL_TOOL="wget"
    echo "==> Using wget (fallback: curl)"
elif command -v curl >/dev/null 2>&1; then
    DL_TOOL="curl"
    echo "==> Using curl (wget not available)"
else
    echo "ERROR: Neither wget nor curl is available"
    exit 1
fi

mkdir -p downloads

echo "==> Arch: $ARCH, CANN: $CANN_VERSION, SOC: $SOC, Python: $PYTHON_VERSION, torch: $TORCH_VERSION"
echo

# Download with progress; alternates wget and curl (preferring wget) and retries
# on failure. Covers servers/proxies that reject one tool, transient errors, and
# HTTP error pages: curl uses -f to fail on HTTP >= 400, and a partial file is
# removed before each retry.
download_file() {
    local url="$1"
    local output="$2"
    local referer="${3:-}"     # optional Referer header (required by OBS)
    local temp="${output}.tmp"

    for ((round = 1; round <= 4; round++)); do
        if ((round % 2 == 1)); then
            # wget: -O = output file (capital O), -c = resume
            # --progress=bar:force shows a real progress bar (like curl) instead
            # of dot-style output; redirected to stderr so it survives pipes.
            local cmd=(wget --progress=bar:force --tries=3 -c -O "${temp}")
            [ -n "$referer" ] && cmd+=(--header="Referer: ${referer}")
            cmd+=("${url}")
        else
            # curl: -o = output, -f = fail on HTTP >= 400, -C - = resume, -L = follow
            local cmd=(curl -fL --progress-bar --retry 3 -C - -o "${temp}")
            [ -n "$referer" ] && cmd+=(-H "Referer: ${referer}")
            cmd+=("${url}")
        fi

        if "${cmd[@]}"; then
            mv "${temp}" "${output}"
            return 0
        fi

        echo "    attempt ${round}/4 failed, retrying ..."
        rm -f "${temp}"
        sleep 5
    done

    echo "    ERROR: download failed after 4 attempts"
    return 1
}

# Verify a downloaded wheel is a real zip (starts with PK); retry on corruption
download_wheel() {
    local url="$1"
    local output="$2"

    for attempt in 1 2 3; do
        download_file "${url}" "${output}" || return 1
        if head -c 2 "${output}" | grep -q "PK"; then
            echo "    OK: ${output}"
            return 0
        fi
        echo "    corrupt download (attempt ${attempt}/3), retrying ..."
        rm -f "${output}"
    done

    echo "    ERROR: corrupt wheel after 3 attempts"
    return 1
}

# 1. Python source
PY_FILE="Python-${PYTHON_VERSION}.tgz"
PY_URL="https://repo.huaweicloud.com/python/${PYTHON_VERSION}/${PY_FILE}"
if [ -f "downloads/${PY_FILE}" ]; then
    echo "[ ] Python source already cached: downloads/${PY_FILE}"
else
    echo "[+] Downloading Python ${PYTHON_VERSION} ..."
    download_file "${PY_URL}" "downloads/${PY_FILE}" || exit 1
fi

# 2. CANN packages (toolkit + ops + nnal)
for pkg in Ascend-cann-toolkit Ascend-cann-${SOC}-ops Ascend-cann-nnal; do
    RUN_FILE="${pkg}_${CANN_VERSION}_linux-${ARCH}.run"
    if [ -f "downloads/${RUN_FILE}" ]; then
        echo "[ ] ${pkg} already cached: downloads/${RUN_FILE}"
        continue
    fi

    echo "[+] Downloading ${pkg} ${CANN_VERSION} for ${ARCH} ..."
    download_file \
        "https://ascend-repo.obs.cn-east-2.myhuaweicloud.com/CANN/CANN%20${CANN_VERSION}/${RUN_FILE}" \
        "downloads/${RUN_FILE}" \
        "https://www.hiascend.com/" || exit 1
done

# 3. torch / torchvision CPU wheels
echo "[+] Downloading torch ${TORCH_VERSION} and torchvision ${TORCHVISION_VERSION} wheels ..."

for pair in "torch:${TORCH_VERSION}" "torchvision:${TORCHVISION_VERSION}"; do
    pkg="${pair%%:*}"
    ver="${pair#*:}"
    whl="${pkg}-${ver}+cpu-${PYTHON_CP}-${PYTHON_CP}-manylinux_2_28_${ARCH}.whl"
    # URL-encode the '+' in the filename: pytorch.org's CDN rejects literal '+'
    # in the path (treats it as a space) and returns 403, but accepts %2B.
    # The local filename keeps the literal '+' (PEP 427 wheel naming).
    whl_url="${pkg}-${ver}%2Bcpu-${PYTHON_CP}-${PYTHON_CP}-manylinux_2_28_${ARCH}.whl"

    if [ -f "downloads/${whl}" ]; then
        echo "[ ] ${pkg} wheel already cached: downloads/${whl}"
        continue
    fi

    url="https://download.pytorch.org/whl/cpu/${whl_url}"
    echo "    ${pkg} ${ver} (${ARCH}) ..."

    download_wheel "${url}" "downloads/${whl}" || exit 1
done

echo
echo "==> All downloads complete!"
echo "    Python: downloads/${PY_FILE}"
echo "    CANN:   downloads/Ascend-cann-*.run (3 packages)"
echo "    torch:  downloads/*.whl"
echo
echo "Run './build.sh' to build the image using these cached files."
