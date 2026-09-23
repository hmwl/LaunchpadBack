#!/bin/bash
# 双击运行：生成给别人用的 build/启动台.zip（Apple 芯片 + Intel 通用），日志写入 build.log
cd "$(dirname "$0")"
bash ./build.sh --dist 2>&1 | tee build.log
echo "EXIT=${PIPESTATUS[0]}" >> build.log
