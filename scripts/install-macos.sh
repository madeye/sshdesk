#!/bin/sh
set -eu
script_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
project_dir="$(dirname -- "${script_dir}")"
install_root="${HOME}/.local/share/sshdesk"
bin_dir="${HOME}/.local/bin"
zig_dir="$(sh "${script_dir}/setup-zig.sh" "${install_root}/toolchain")"
PATH="${zig_dir}:${PATH}"
export PATH
mkdir -p "${install_root}" "${bin_dir}"
(cd "${project_dir}" && sh "${script_dir}/with-zig-sdk.sh" zig build -Doptimize=ReleaseSafe --prefix "${install_root}")
for command in sshdesk sshdesk-local sshdesk-server sshdesk-bench sshdesk-agent sshdesk-agent-ssh sshdesk-forced-command sshdesk-split sshdesk-remote; do
    ln -sfn "${install_root}/bin/${command}" "${bin_dir}/${command}"
done
echo "Installed SSHDESK in ${install_root}. Add ${bin_dir} to PATH."
echo "PNG libraries are bundled; no Python runtime is required."
echo "Grant Screen Recording and Accessibility permission to the installed"
echo "${install_root}/bin/sshdesk-server and ${install_root}/bin/sshdesk-agent executables."
