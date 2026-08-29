#!/usr/bin/env bash
#
# build.sh - 把当前目录打包成可刷的 Magisk / KernelSU 模块 zip
#
# 用法:
#   sh build.sh               # 输出 <version>.zip (版本取自 module.prop)
#   sh build.sh out.zip       # 指定输出文件名
#
# 为什么用 python 打包:
#   Windows 工作副本没有 Unix 可执行权限位 (bin/uperf、*.sh 全是 644),
#   直接打包会让脚本和二进制在手机上无法执行。zipfile 可以显式指定
#   external_attr, 精确写入 0755 / 0644。
#   (setup.sh 末尾也有 chmod 755 兜底, 但 zip 里带对权限更稳妥。)
#
# 为什么没有用 zip 命令:
#   Git Bash 不自带 zip, 依赖越少越可靠。

set -eu

cd "$(dirname "$0")"

# 版本号取自 module.prop (module.prop 是模块身份的唯一事实来源)
VERSION=$(grep -E '^version=' module.prop 2>/dev/null | head -n 1 | cut -d= -f2)
if [ -z "$VERSION" ]; then
    echo "! 无法从 module.prop 读取 version" >&2
    exit 1
fi
OUT="${1:-$VERSION.zip}"

# 探测 python 解释器
PY=""
for c in python3 python py; do
    if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
    echo "! 未找到 python3, 无法打包" >&2
    exit 1
fi

echo "- 版本: $VERSION"
echo "- 输出: $OUT"

"$PY" - "$OUT" <<'PYEOF'
import os
import sys
import zipfile

out = sys.argv[1]
root = os.getcwd()

# 目录级排除 (开发期产物, 不属于模块运行时; 资料/ 是特调源文件, 已并入 config/)
EXCLUDE_DIRS = {'.git', '.workbuddy', '__pycache__', '.idea', '.vscode', '资料'}
# 文件级排除: 构建脚本自身不进包; 已有 zip 不自我嵌套
EXCLUDE_FILES = {'build.sh', '.DS_Store', 'Thumbs.db', 'desktop.ini'}
# 需要 0755 的文件名 (除 *.sh 外): Magisk update-binary 与两个二进制
EXEC_NAMES = {'update-binary', 'uperf', 'busybox'}

entries = []  # (zip 内路径, None=目录)
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDE_DIRS)
    rel_dir = os.path.relpath(dirpath, root)
    if rel_dir != '.':
        entries.append((rel_dir.replace(os.sep, '/') + '/', None))
    for fn in sorted(filenames):
        rel = os.path.relpath(os.path.join(dirpath, fn), root).replace(os.sep, '/')
        if rel in EXCLUDE_FILES:
            continue
        if fn.lower().endswith('.zip'):
            continue
        entries.append((rel, rel))

nfile = 0
with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for name, src in entries:
        if src is None:
            zi = zipfile.ZipInfo(name)
            zi.external_attr = (0o040000 | 0o755) << 16
            z.writestr(zi, b'')
            continue
        base = os.path.basename(src)
        perm = 0o755 if (base.endswith('.sh') or base in EXEC_NAMES) else 0o644
        zi = zipfile.ZipInfo(name)
        zi.external_attr = (0o100000 | perm) << 16
        zi.compress_type = zipfile.ZIP_DEFLATED
        with open(os.path.join(root, src), 'rb') as f:
            z.writestr(zi, f.read())
        nfile += 1

print("- 已打包 %d 个文件" % nfile)
PYEOF

echo "- 完成: $OUT"
