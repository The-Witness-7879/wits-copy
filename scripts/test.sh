#!/usr/bin/env bash
#
# Wit's Copy 统一测试入口。
#
# 固定结果包路径、DerivedData、并发、诊断收集和结果保留数量。
#
# 用法：
#   ./scripts/test.sh                                  # 安全单元：WitsCopyTests，跳过剪贴板与 UI
#   ./scripts/test.sh -only-testing:WitsCopyTests/Foo     # 聚焦，仍不跑 UI
#   ./scripts/test.sh --ui                             # 显式包含 UI
#   ./scripts/test.sh -only-testing:WitsCopyUITests       # 参数点名 UI 也算显式
#   WITSCOPY_INCLUDE_CLIPBOARD=1 ./scripts/test.sh        # 连会碰真实剪贴板的测试一起跑
#   WITSCOPY_INCLUDE_UI=1 ./scripts/test.sh               # 同 --ui
#
# 环境变量：
#   WITSCOPY_KEEP_RESULTS         保留最近几个结果包（默认 10）
#   WITSCOPY_INCLUDE_CLIPBOARD=1  不再跳过 WitsCopyTests/ClipboardTests
#   WITSCOPY_INCLUDE_UI=1         允许 UI。默认禁止，避免无意拉起 UI runner
#   WITSCOPY_DESTINATION          覆盖 destination（默认 platform=macOS）
#   DEVELOPER_DIR              覆盖 Xcode 路径

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"


DERIVED="$ROOT/lab/.derived"
RESULTS="$ROOT/lab/results"
KEEP="${WITSCOPY_KEEP_RESULTS:-10}"
DESTINATION="${WITSCOPY_DESTINATION:-platform=macOS}"

mkdir -p "$DERIVED" "$RESULTS"
# Spotlight 不必反复扫构建缓存。
touch "$DERIVED/.metadata_never_index" "$RESULTS/.metadata_never_index"

STAMP="$(date +%Y%m%d-%H%M%S)"
BUNDLE="$RESULTS/test-$STAMP.xcresult"

INCLUDE_UI=0
if [ "${WITSCOPY_INCLUDE_UI:-0}" = "1" ]; then
  INCLUDE_UI=1
fi

FILTERED=()
for arg in "$@"; do
  case "$arg" in
    --ui)
      INCLUDE_UI=1
      ;;
    *)
      FILTERED+=("$arg")
      ;;
  esac
done

for arg in ${FILTERED[@]+"${FILTERED[@]}"}; do
  case "$arg" in
    *WitsCopyUITests*)
      INCLUDE_UI=1
      ;;
  esac
done

HAS_ONLY=0
for arg in ${FILTERED[@]+"${FILTERED[@]}"}; do
  case "$arg" in
    -only-testing:*)
      HAS_ONLY=1
      ;;
  esac
done

SKIP_ARGS=()
if [ "${WITSCOPY_INCLUDE_CLIPBOARD:-0}" != "1" ]; then
  SKIP_ARGS+=("-skip-testing:WitsCopyTests/ClipboardTests")
fi

# 默认只跑安全单元。没有显式 UI 请求时，额外参数也不能把 UI runner 带进来。
if [ "$INCLUDE_UI" != "1" ]; then
  if [ "$HAS_ONLY" = "0" ]; then
    SKIP_ARGS+=("-only-testing:WitsCopyTests")
  fi
  SKIP_ARGS+=("-skip-testing:WitsCopyUITests")
fi

echo "==> 结果包: $BUNDLE"
echo "==> DerivedData: $DERIVED (复用，不再每次新建)"
if [ "$INCLUDE_UI" = "1" ]; then
  echo "==> UI: 显式打开"
else
  echo "==> UI: 关闭（--ui 或 WITSCOPY_INCLUDE_UI=1 或 -only-testing:WitsCopyUITests 才打开）"
fi

# 测试签名沿用已能跑通的 adhoc 关闭。可安装包不要走这个开关。
# nice -n 10 与 -jobs 2 限制本机并发，不新开 DerivedData。
set +e
nice -n 10 xcodebuild test \
  -project WitsCopy.xcodeproj \
  -scheme WitsCopy \
  -configuration Debug \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED" \
  -resultBundlePath "$BUNDLE" \
  -jobs 2 \
  -collect-test-diagnostics never \
  -enableCodeCoverage NO \
  -parallel-testing-enabled NO \
  CODE_SIGNING_ALLOWED=NO \
  ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"} \
  ${FILTERED[@]+"${FILTERED[@]}"}
STATUS=$?
set -e

pruned=0
while IFS= read -r old; do
  [ -n "$old" ] || continue
  rm -rf "$old"
  pruned=$((pruned + 1))
done < <(ls -dt "$RESULTS"/*.xcresult 2>/dev/null | tail -n +$((KEEP + 1)))

if [ "$pruned" -gt 0 ]; then
  echo "==> 清理 $pruned 个旧结果包，保留最近 $KEEP 个"
fi

echo "==> 当前 lab/results 占用: $(du -sh "$RESULTS" | cut -f1)"
echo "==> 退出码: $STATUS"
echo "==> 结果包路径: $BUNDLE"
exit "$STATUS"
