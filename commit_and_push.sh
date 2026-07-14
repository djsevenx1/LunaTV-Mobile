#!/bin/bash
# 在 djsevenx1/CORSAPI 仓库根目录执行:

# 1. 备份原文件
cp _worker.js _worker.js.bak

# 2. 替换成新版本(用户从 /workspace/corsapi_worker.js 拷过来)
# 假设用户已经把新文件拷到 _worker.js.new
cp _worker.js.new _worker.js

# 3. 提交
git add _worker.js
git commit -F /workspace/commit_msg.txt
# 或者: git commit -m "v2.0.20d: 禁用 HTTP/3 (QUIC) — 修 SSLV3_ALERT_HANDSHAKE_FAILURE"

# 4. 推送
git push origin main
