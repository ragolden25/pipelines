#!/bin/bash
# guac_http_redirect.sh - Guacamole nginx answers port 80 with a 301 redirect to HTTPS, like the
# Grafana stack. Run as ansible on ansible-forge:   bash guac_http_redirect.sh
#   1. nginx/conf.d/guacamole.conf in the CURRENT quarter delivery: adds a port 80 server block that
#      only redirects (mirrors the 443 block's IPv6 listen). New quarters seed from the previous one,
#      and the weekly Molecule test copies its config from avocado/current, so both pick it up.
#      Skipped if the file already has a port 80 listener.
#   2. /opt/ansible/files/avocado/docker-compose.yml.j2: nginx publishes 80:80 as well as 443:443.
#   3. Guacamole Molecule verify.yml: checks that plain HTTP gets a 301 to https://.
#   4. this week's already-rendered weekly compose files (molecule/weekly/avocado/<newest week>): same
#      port, plus the guacamole read-only fix, so the Molecule test can be re-run today instead of
#      waiting for next Thursday's build to render them again.
# The firewall role already allows the http service. Backups of every file it changes go to
# /opt/ansible/molecule/backups/guac-http-<date>/. Safe to run twice.

set -euo pipefail
[ "$(id -un)" = ansible ] || { echo "run this as ansible"; exit 1; }
CONF=$(readlink -f /opt/ansible/files/avocado/current)/nginx/conf.d/guacamole.conf
TPL=/opt/ansible/files/avocado/docker-compose.yml.j2
VER=/opt/ansible/nucleus/roles/configure_guacamole/molecule/guac16/verify.yml
BK=/opt/ansible/molecule/backups/guac-http-$(date +%F-%H%M)
mkdir -p "$BK"
WEEK=$(ls -td /opt/ansible/molecule/weekly/avocado/*/ 2>/dev/null | head -1)
for f in "$CONF" "$TPL" "$VER"; do
  [ -f "$f" ] || { echo "missing $f - nothing changed"; exit 1; }
  cp -p "$f" "$BK/$(echo "$f" | tr / _)"
done

for f in "$WEEK"docker-compose.yml "$WEEK"docker-compose-ccop.yml; do
  [ -f "$f" ] && cp -p "$f" "$BK/$(echo "$f" | tr / _)"
done

python3 - "$CONF" "$TPL" "$VER" "$WEEK" <<'EOF'
import re, sys
import os
conf, tpl, ver, week = sys.argv[1:]

def publish_80(s, where):
    i = s.index('\n  nginx:')
    nginx = s[i:]
    if re.search(r'^\s*- "80:80"', nginx, re.M):
        print('   %s: nginx already publishes 80' % where); return s
    old = '      - "443:443"\n'
    assert nginx.count(old) == 1, 'nginx 443 port line not found once in %s - nothing changed' % where
    print('   %s: nginx now publishes 80:80 and 443:443' % where)
    return s[:i] + nginx.replace(old, '      - "80:80"\n' + old, 1)

# 1. nginx: port 80 -> 301 https
s = open(conf).read()
if re.search(r'^\s*listen\s+(\[::\]:)?80\b', s, re.M):
    print('1. %s already listens on port 80 - left unchanged' % conf)
else:
    v6 = '    listen [::]:80;\n' if re.search(r'^\s*listen\s+\[::\]:443\b', s, re.M) else ''
    s = s.rstrip('\n') + '''

# HTTP: answer every plain-HTTP request with a permanent redirect to HTTPS (same as the Grafana stack),
# so users never have to type https://. Nothing is served over HTTP.
server {
    listen 80;
%s    server_name _;
    return 301 https://$host$request_uri;
}
''' % v6
    open(conf, 'w').write(s)
    print('1. added the port 80 redirect block to %s%s' % (conf, ' (IPv4 + IPv6)' if v6 else ' (IPv4)'))

# 2. compose template: publish 80 on nginx
print('2. compose template')
t = publish_80(open(tpl).read(), tpl)
open(tpl, 'w').write(t)

# 3. Molecule verify: plain HTTP must be a 301 to https
s = open(ver).read()
if 'Plain HTTP is redirected to HTTPS' in s:
    print('3. verify.yml already checks the redirect - left unchanged')
else:
    anchor = '''        - name: Login, data and proxy checks
          ansible.builtin.assert:
            that:
'''
    assert s.count(anchor) == 1, 'assert block not found once in %s - nothing changed' % ver
    s = s.replace(anchor, '''        - name: Plain HTTP is redirected to HTTPS
          ansible.builtin.uri:
            url: "http://127.0.0.1/guacamole/"
            headers:
              Host: "{{ site }}"
            follow_redirects: none
            status_code: [301]
          register: via_http

''' + anchor + '''              - via_http.status == 301
              - via_http.location | default('') is match('https://')
''', 1)
    s = s.replace('''              nginx_status={{ via_nginx.status | default('?') }}
''', '''              nginx_status={{ via_nginx.status | default('?') }}
              http_redirect={{ via_http.status | default('?') }} {{ via_http.location | default('') }}
''', 1)
    s = s.replace('#   - nginx serves Guacamole over TLS\n', '#   - nginx serves Guacamole over TLS, and answers plain HTTP with a 301 to HTTPS\n', 1)
    open(ver, 'w').write(s)
    print('3. verify.yml: added the HTTP -> HTTPS redirect check')

# 4. this week's rendered compose files: port 80 + guacamole without read-only root (Tomcat)
print('4. weekly compose files in %s' % (week or '(no weekly folder found)'))
ro = """    read_only: true
    tmpfs:
      - /tmp
      - /usr/local/tomcat/temp
      - /usr/local/tomcat/work
      - /usr/local/tomcat/logs
"""
for name in ('docker-compose.yml', 'docker-compose-ccop.yml'):
    f = os.path.join(week, name) if week else ''
    if not f or not os.path.isfile(f):
        continue
    try:
        s = publish_80(open(f).read(), f)
    except (AssertionError, ValueError) as e:
        print('   WARNING: %s - left unchanged' % e); continue
    if s.count(ro) == 1:
        s = s.replace(ro, ''); print('   %s: guacamole read_only + tmpfs removed' % f)
    open(f, 'w').write(s)
EOF

echo
echo "Backups: $BK"
echo "Takes effect on the next deployment. To see it now on the guac VM: run-guac16.sh deploy nucleus"
