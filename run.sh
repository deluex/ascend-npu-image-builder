#!/usr/bin/env bash
# Run the Ascend NPU container. Must be executed on a host with an Ascend NPU
# and the driver installed.
#
# Two options:
#   A. Ascend Docker Runtime installed:
#      docker run --runtime ascend --device all ...
#   B. Mount devices and host driver manually (default of this script,
#      compatible with docker / podman / buildah run)
#
# NOTE: /usr/local/Ascend/driver inside the container must come from the host;
# the image itself does NOT contain the driver (HDK).
set -euo pipefail

: "${IMAGE:=ascend-npu:9.1.0-torch2.9.0-910b}"
: "${NAME:=ascend-npu}"

DEVICE_ARGS=""
for d in /dev/davinci_manager /dev/hisi_hdc /dev/devmm_svm /dev/davinci*; do
    [ -e "$d" ] && DEVICE_ARGS="${DEVICE_ARGS} --device $d"
done

if [ -z "$DEVICE_ARGS" ]; then
    echo "!!! No /dev/davinci* devices found. Make sure the host driver is installed and 'npu-smi info' works." >&2
fi

MOUNT_ARGS=""
for m in \
    "/usr/local/Ascend/driver:/usr/local/Ascend/driver" \
    "/usr/local/dcmi:/usr/local/dcmi" \
    "/usr/local/bin/npu-smi:/usr/local/bin/npu-smi" \
    "/usr/local/Ascend/driver/lib64/pluginupgrade:/usr/local/Ascend/driver/lib64/pluginupgrade" \
    "/etc/ascend_install.info:/etc/ascend_install.info" \
    "/etc/Ascend/ascend_install.info:/etc/Ascend/ascend_install.info" \
; do
    src="${m%%:*}"
    [ -e "$src" ] && MOUNT_ARGS="${MOUNT_ARGS} -v $m"
done

echo ">>> starting container ${NAME} (image ${IMAGE})"
echo ">>> devices:${DEVICE_ARGS:- none}"
echo ">>> mounts:${MOUNT_ARGS:- none}"

exec docker run -it --rm --name "${NAME}" \
    --ipc=host \
    --network=host \
    ${DEVICE_ARGS} \
    ${MOUNT_ARGS} \
    "${IMAGE}" "$@"
