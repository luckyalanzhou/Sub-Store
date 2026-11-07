FROM qidian-luci-preview:latest
COPY run/payload/root/www/luci-static/resources/view/sub-store/ /www/luci-static/resources/view/sub-store/
COPY run/payload/root/usr/share/luci/menu.d/luci-app-sub-store.json /usr/share/luci/menu.d/
COPY run/payload/root/usr/share/rpcd/acl.d/luci-app-sub-store.json /usr/share/rpcd/acl.d/
COPY scripts/luci-preview/start.sh /usr/local/bin/sub-store-preview
COPY scripts/luci-preview/status.sh /usr/lib/sub-store/status
COPY scripts/luci-preview/job.sh /usr/lib/sub-store/job.sh
RUN chmod +x /usr/local/bin/sub-store-preview /usr/lib/sub-store/status /usr/lib/sub-store/job.sh
EXPOSE 80
ENTRYPOINT ["/bin/sh", "/usr/local/bin/sub-store-preview"]
