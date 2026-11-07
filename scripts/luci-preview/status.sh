#!/bin/sh
state=$(cat /tmp/sub-store-preview-state)
action=$(cat /tmp/sub-store-preview-action 2>/dev/null || echo '')
id=$(cat /tmp/sub-store-preview-operation-id 2>/dev/null || echo 0)
printf '{"container":"%s","action":"%s","operation_id":"%s","phase":"success","health":"healthy","url":"http://127.0.0.1:3001/","busy":false,"version":"preview","app_version":"preview","image":"xream/sub-store:latest","output":"预览日志","container_log":"预览运行日志"}\n' "$state" "$action" "$id"
