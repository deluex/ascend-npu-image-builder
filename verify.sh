#!/usr/bin/env bash
# In-image smoke test: Python / tools / CANN / torch / torch_npu
set -u

echo "===== 1. Python ====="
python3 --version || true
pip --version || true
which python3 pip || true

echo
echo "===== 2. Common tools ====="
for t in ping nslookup tmux pkill pskill tree g++ make cmake git curl wget; do
    printf "%-10s -> %s\n" "$t" "$(command -v $t 2>/dev/null || echo MISSING)"
done

echo
echo "===== 3. CANN Toolkit ====="
echo "ASCEND_TOOLKIT_HOME=${ASCEND_TOOLKIT_HOME:-unset}"
ls /usr/local/Ascend/ 2>/dev/null || true
if [ -x "${ASCEND_TOOLKIT_HOME:-/nonexist}/bin/atc" ]; then
    "${ASCEND_TOOLKIT_HOME}/bin/atc" --version 2>&1 | head -5 || true
else
    echo "atc not found"
fi

echo
echo "===== 4. torch / torch_npu ====="
python3 - <<'EOF'
import sys
try:
    import torch
    print("torch:", torch.__version__, "| python:", sys.version.split()[0])
except Exception as e:
    print("torch import failed:", e)
    sys.exit(0)
try:
    import torch_npu
    print("torch_npu:", torch_npu.__version__)
except Exception as e:
    print("torch_npu import failed:", e)

# Requires an NPU device (host driver mounted); fails without one
try:
    import torch_npu
    print("npu.is_available():", torch.npu.is_available())
except Exception as e:
    print("npu detection failed (expected without a device):", e)
EOF

echo
echo "===== 5. torch C++ API (bundled with the pip package) ====="
TORCH_ROOT=$(python3 -c 'import torch,os;print(os.path.dirname(torch.__file__))' 2>/dev/null || true)
if [ -n "${TORCH_ROOT}" ] \
   && [ -f "${TORCH_ROOT}/lib/libtorch.so" ] \
   && [ -f "${TORCH_ROOT}/include/torch/csrc/api/include/torch/torch.h" ] \
   && [ -f "${TORCH_ROOT}/share/cmake/Torch/TorchConfig.cmake" ]; then
    echo "torch C++ OK: ${TORCH_ROOT}"
    ls "${TORCH_ROOT}/lib/" | grep -c '\.so' | xargs echo "shared libraries:"
    echo "CMake package: ${TORCH_ROOT}/share/cmake/Torch (find_package(Torch) usable)"
else
    echo "torch C++ API INCOMPLETE (TORCH_ROOT=${TORCH_ROOT:-unresolved})"
fi

echo
echo "===== 6. NPU status (requires host driver) ====="
if command -v npu-smi >/dev/null 2>&1; then
    npu-smi info || true
else
    echo "npu-smi unavailable; check that the host driver is mounted (see run.sh)"
fi
