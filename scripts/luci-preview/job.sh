#!/bin/sh
id=$(cat /tmp/sub-store-preview-operation-id 2>/dev/null || echo 0)
echo $((id + 1)) > /tmp/sub-store-preview-operation-id
echo "$2" > /tmp/sub-store-preview-action
case "$2" in
 install|service-start|service-restart) echo running > /tmp/sub-store-preview-state ;;
 stop) echo exited > /tmp/sub-store-preview-state ;;
 delete-container) echo not-created > /tmp/sub-store-preview-state ;;
esac
echo accepted
