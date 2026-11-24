#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<'EOF'
Usage: apply.sh [--check] [--source PATH]

Apply the mako platform patches to a LineageOS 23.2 checkout.
The source root defaults to the current directory.
--check validates every patch without applying it.

The standalone media patch is used by device/lge/mako/media/rebuild-msm8960-avc.sh.
EOF
}

fail() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

check_only=false
source_root=$PWD
while (( $# )); do
    case $1 in
        --check) check_only=true; shift ;;
        --source)
            (( $# >= 2 )) || fail '--source requires a path'
            source_root=$2
            shift 2
            ;;
        -h|--help) usage; exit ;;
        *) fail "unknown option: $1" ;;
    esac
done

kit=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
source_root=$(cd -- "$source_root" && pwd -P) || fail 'invalid source root'
[[ -d $source_root/.repo ]] || fail "not an Android checkout: $source_root"

export LC_ALL=C
shopt -s globstar nullglob
patches=("$kit"/patches/**/0001-mako.patch)
(( ${#patches[@]} )) || fail 'no platform patches found'
pending=()
projects=()

for patch in "${patches[@]}"; do
    project=${patch#"$kit/patches/"}
    project=${project%/*}
    repo=$source_root/$project
    top=$(git -C "$repo" rev-parse --show-toplevel 2>/dev/null) ||
        fail "missing Git project: $project"
    [[ $top == "$repo" ]] || fail "unexpected Git checkout: $project"
    [[ -z $(git -C "$repo" ls-files --unmerged) ]] || fail "unresolved Git conflicts: $project"

    if git -C "$repo" apply --reverse --check --whitespace=nowarn "$patch" 2>/dev/null; then
        printf 'Already applied: %s\n' "$project"
    elif git -C "$repo" apply --check --whitespace=nowarn "$patch"; then
        printf 'Ready: %s\n' "$project"
        projects+=("$repo")
        pending+=("$patch")
    else
        fail "patch conflicts with $project"
    fi
done

if "$check_only"; then
    printf 'Checked %s patches. %s to apply.\n' "${#patches[@]}" "${#pending[@]}"
    exit 0
fi

applied=0
rollback() {
    local i
    for (( i=applied-1; i>=0; i-- )); do
        if ! git -C "${projects[i]}" apply --reverse --whitespace=nowarn "${pending[i]}"; then
            printf 'Could not revert the patch in %s\n' "${projects[i]}" >&2
        fi
    done
}

trap 'rollback; exit 130' INT
trap 'rollback; exit 143' TERM
for i in "${!pending[@]}"; do
    if ! git -C "${projects[i]}" apply --whitespace=nowarn "${pending[i]}"; then
        rollback
        fail "could not apply the patch in ${projects[i]}"
    fi
    (( applied += 1 ))
done
trap - INT TERM

printf 'Applied %s patches. %s already present.\n' "$applied" "$(( ${#patches[@]} - applied ))"
