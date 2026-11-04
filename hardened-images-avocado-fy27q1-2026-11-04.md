# Hardened image facts: avocado/fy27q1

Generated 2026-11-04T11:43:33-05:00 on ansible-forge from `/opt/ansible/files/avocado/fy27q1/images`. Read from the image files themselves.

| Image | User | Entrypoint | Shells | Network/download tools | Package managers | Admin/setuid tools | setuid/setgid files | dpkg packages |
|---|---|---|---|---|---|---|---|---|
| `nucleus/guacamole:1.6.0` | tomcat | `bin/catalina.sh run` | dash sh | none | none | mount | mount newgrp umount unix_chkpwd  | 0 |
| `nucleus/guacd:1.6.0` | root (unset) | `/usr/local/sbin/guacd -f -b 0.0.0.0` | none | none | none | mount | mount newgrp umount unix_chkpwd  | 0 |
| `nucleus/nginx:1.31.6` | 65532:65532 | `/usr/sbin/nginx -g daemon off;` | none | none | none | mount | mount newgrp umount unix_chkpwd  | 0 |
| `nucleus/postgres:18.6` | 70:70 | `/usr/local/bin/docker-entrypoint.sh postgres` | bash dash sh | none | none | mount | mount newgrp umount unix_chkpwd  | 0 |

## Runtime settings from `/opt/ansible/files/avocado/docker-compose.yml.j2`

