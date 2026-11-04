# Hardened image facts: grafana/fy27q1

Generated 2026-11-04T11:45:03-05:00 on ansible-forge from `/opt/ansible/files/grafana/fy27q1/images`. Read from the image files themselves.

| Image | User | Entrypoint | Shells | Network/download tools | Package managers | Admin/setuid tools | setuid/setgid files | dpkg packages |
|---|---|---|---|---|---|---|---|---|
| `nucleus/grafana:12.4.11` | 65532:65532 | `/usr/local/bin/grafana server --homepath=/usr/share/grafana --config=/etc/grafana/grafana.ini` | none | none | none | su | chfn chsh expiry gpasswd newgrp su unix_chkpwd  | 0 |
| `nucleus/idrac:2.6.3` | 65532:65532 | `/usr/local/bin/idrac-exporter --config=/etc/idrac-exporter/config.yml` | none | none | none | su | chfn chsh expiry gpasswd newgrp su unix_chkpwd  | 0 |
| `nucleus/nginx:1.31.6` | 65532:65532 | `/usr/sbin/nginx -g daemon off;` | none | none | none | su | chfn chsh expiry gpasswd newgrp su unix_chkpwd  | 0 |
| `nucleus/prometheus:3.14.0` | 65532:65532 | `/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/var/prometheus` | none | none | none | su | chfn chsh expiry gpasswd newgrp su unix_chkpwd  | 0 |

## Runtime settings from `/opt/ansible/files/grafana/docker-compose.yml.j2`

| Service | User | Read-only root | cap_drop | cap_add | security_opt | Published ports | CPU / memory limit |
|---|---|---|---|---|---|---|---|
| grafana | image default | yes | ALL | — | no-new-privileges:true, seccomp=/usr/share/containers/seccomp.json | 127.0.0.1:3000:3000 | none |
| prometheus | image default | yes | ALL | — | no-new-privileges:true, seccomp=/usr/share/containers/seccomp.json | 127.0.0.1:9191:9191 | none |
| nginx | 65532:65532 | yes | ALL | NET_BIND_SERVICE | no-new-privileges:true, seccomp=/usr/share/containers/seccomp.json | 80:80, 443:443 | none |
| idrac_exporter | image default | yes | ALL | — | no-new-privileges:true, seccomp=/usr/share/containers/seccomp.json | 127.0.0.1:9348:9348 | none |
