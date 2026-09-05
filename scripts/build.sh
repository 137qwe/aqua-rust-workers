#!/usr/bin/env bash
# AQUA Worker Linux 构建脚本（scripts/build.ps1 的等价实现）
# 适用：Cloudflare Workers Builds 网页构建（Linux 容器）/ 本地 Linux / macOS
# 用法: bash scripts/build.sh gateway | frontend
set -euo pipefail

TARGET="${1:-}"
if [ "$TARGET" != "gateway" ] && [ "$TARGET" != "frontend" ]; then
  echo "用法: bash scripts/build.sh gateway|frontend" >&2
  exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CRATE="$ROOT/$TARGET"
BUILD_DIR="$CRATE/build"
STAGING="$BUILD_DIR/staging"
WORKER_DIR="$BUILD_DIR/worker"
WBG_VERSION="0.2.127" # 必须与 Cargo.lock 中 wasm-bindgen 版本精确一致

# 1. 确保 wasm 编译目标存在（已安装则秒过）
rustup target add wasm32-unknown-unknown

# 2. 准备 wasm-bindgen CLI（优先复用 .tools；缺失则自动下载 musl 静态版，glibc/musl 系统均可运行）
WBG_DIR="$ROOT/.tools/wasm-bindgen-${WBG_VERSION}-x86_64-unknown-linux-musl"
WBG="$WBG_DIR/wasm-bindgen"
if [ ! -x "$WBG" ]; then
  echo ">> 下载 wasm-bindgen ${WBG_VERSION} ..."
  mkdir -p "$ROOT/.tools"
  curl -fsSL "https://github.com/rustwasm/wasm-bindgen/releases/download/${WBG_VERSION}/wasm-bindgen-${WBG_VERSION}-x86_64-unknown-linux-musl.tar.gz" -o /tmp/wbg.tgz
  tar xzf /tmp/wbg.tgz -C "$ROOT/.tools"
  rm -f /tmp/wbg.tgz
fi
chmod +x "$WBG"

# 3. 编译为 wasm（WASM_BINDGEN_USE_JS_SYS 是 worker-rs 运行所必需）
export WASM_BINDGEN_USE_JS_SYS=1
cd "$CRATE"
cargo build --target wasm32-unknown-unknown --release

# 4. 定位 wasm 产物（遵循 cargo 的 target 目录规则；排除 *.d.* 等非主产物）
CARGO_TARGET_DIR="${CARGO_TARGET_DIR:-$CRATE/target}"
WASM="$(find "$CARGO_TARGET_DIR/wasm32-unknown-unknown/release" -maxdepth 1 -name '*.wasm' ! -name '*.d.*' | head -1)"
if [ -z "$WASM" ]; then
  echo "未找到 wasm 编译产物" >&2
  exit 1
fi

# 5. wasm-bindgen 生成 JS 胶水（bundler target，legacy 风格）
rm -rf "$STAGING"
mkdir -p "$STAGING"
"$WBG" "$WASM" --no-typescript --target bundler --out-name index --out-dir "$STAGING"

# 6. 组装 worker/ 目录
rm -rf "$WORKER_DIR"
mkdir -p "$WORKER_DIR"
cp "$STAGING/index_bg.js" "$WORKER_DIR/"
cp "$STAGING/index_bg.wasm" "$WORKER_DIR/index.wasm"
[ -d "$STAGING/snippets" ] && cp -r "$STAGING/snippets" "$WORKER_DIR/"

# 7. 由模板生成 shim.js（等价 build.ps1 中三个占位符 Replace 为空）
sed -e 's/\$WAIT_UNTIL_RESPONSE//g' \
    -e 's/\$SNIPPET_JS_IMPORTS//g' \
    -e 's/\$SNIPPET_WASM_IMPORTS//g' \
    "$ROOT/scripts/shim.legacy.template.js" > "$WORKER_DIR/shim.js"

# 8. esbuild 打包为 shim.mjs（根目录没装依赖则先安装）
ESB="$ROOT/node_modules/.bin/esbuild"
if [ ! -x "$ESB" ]; then
  npm install --prefix "$ROOT"
fi
( cd "$WORKER_DIR" && \
  node "$ROOT/node_modules/.bin/esbuild" \
    --external:./index.wasm --external:cloudflare:email \
    --external:cloudflare:sockets --external:cloudflare:workers \
    --format=esm --bundle ./shim.js --outfile=shim.mjs --allow-overwrite --minify )

# 9. 清理中间文件
rm -f "$WORKER_DIR/shim.js" "$WORKER_DIR/index_bg.js"
rm -rf "$STAGING"

KB=$(du -k "$WORKER_DIR/shim.mjs" | cut -f1)
WKB=$(du -k "$WORKER_DIR/index.wasm" | cut -f1)
echo "[$TARGET] OK -> $WORKER_DIR (shim.mjs ${KB}KB, wasm ${WKB}KB)"
