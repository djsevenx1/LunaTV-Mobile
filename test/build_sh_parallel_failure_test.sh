#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

cp "$repo_root/build.sh" "$tmp_dir/build.sh"
chmod +x "$tmp_dir/build.sh"

cat > "$tmp_dir/pubspec.yaml" <<'YAML'
name: lunatv_test
version: 1.2.3+4
YAML

mkdir -p "$tmp_dir/bin"
cat > "$tmp_dir/bin/flutter" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --version)
    echo "Flutter test stub"
    exit 0
    ;;
  clean)
    exit 0
    ;;
  pub)
    exit 0
    ;;
  build)
    exit 42
    ;;
  *)
    echo "unexpected flutter command: $*" >&2
    exit 99
    ;;
esac
SH
chmod +x "$tmp_dir/bin/flutter"

set +e
output="$(cd "$tmp_dir" && PATH="$tmp_dir/bin:$PATH" ./build.sh --android-only 2>&1)"
status=$?
set -e

if [ "$status" -eq 0 ]; then
  echo "expected build.sh to fail when a parallel child build fails"
  echo "$output"
  exit 1
fi

if ! grep -q "至少一个并行构建任务失败" <<<"$output"; then
  echo "expected build.sh to report the parallel child failure"
  echo "$output"
  exit 1
fi

if grep -q "复制构建产物到根目录" <<<"$output"; then
  echo "expected build.sh to stop before copying artifacts after a child failure"
  echo "$output"
  exit 1
fi
