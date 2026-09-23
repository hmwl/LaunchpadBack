#!/bin/bash
# 双击运行：编译并安装到 /Applications，日志写入 build.log
cd "$(dirname "$0")"
bash ./build.sh --install 2>&1 | tee build.log
echo "EXIT=${PIPESTATUS[0]}" >> build.log
