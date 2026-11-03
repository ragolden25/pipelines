tar -czf /root/pre-compose-backup-$(date +%F).tar.gz -C / opt/ansible/files/avocado/docker-compose.yml.j2 opt/ansible/nucleus/roles/weekly_common/tasks opt/ansible/nucleus/roles/configure_guacamole/vars opt/ansible/nucleus/roles/configure_guacamole/molecule/guac16/prepare.yml
tar -xzf /home/ansible/guac-compose-weekly.tar.gz -C /
rm -f /opt/ansible/nucleus/roles/configure_guacamole/templates/docker-compose-ccop.yml.j2
chown -R ansible:ansible-admin /opt/ansible/files/avocado/docker-compose.yml.j2 /opt/ansible/nucleus/roles/weekly_common /opt/ansible/nucleus/roles/configure_guacamole /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml

I'm having a heck of a time with this previous set of commands!!!

[root@ansible-forge ~]# tar -czf /root/pre-compose-backup-$(date +%F).tar.gz -C / opt/ansible/files/avocado/docker-compose.yml.j2 opt/ansible/nucleus/roles/weekly_common/tasks opt/ansible/nucleus/roles/configure_guacamole/vars opt/ansible/nucleus/roles/configure_guacamole/molecule/guac16/prepare.yml
tar -xzf /home/ansible/guac-compose-weekly.tar.gz -C /
rm -f /opt/ansible/nucleus/roles/configure_guacamole/templates/docker-compose-ccop.yml.j2
chown -R ansible:ansible-admin /opt/ansible/files/avocado/docker-compose.yml.j2 /opt/ansible/nucleus/roles/weekly_common /opt/ansible/nucleus/roles/configure_guacamole /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml

tar (child): /home/ansible/guac-compose-weekly.tar.gz: Cannot open: No such file or directory
tar (child): Error is not recoverable: exiting now
tar: Child returned status 2
tar: Error is not recoverable: exiting now
chown: cannot access '/opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml': No such file or directory
[root@ansible-forge ~]# mv guac-compose-weekly.tar.gz /home/ansible/
[root@ansible-forge ~]# cd /home/ansible/
[root@ansible-forge ansible]# chown ansible:ansible guac-compose-weekly.tar.gz
[root@ansible-forge ansible]# chown -R ansible:ansible-admin /opt/ansible/files/avocado/docker-compose.yml.j2 /opt/ansible/nucleus/roles/weekly_common /opt/ansible/nucleus/roles/configure_guacamole /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml
chown: cannot access '/opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml': No such file or directory


[root@ansible-forge ansible]# ./install-guac-compose.sh
[12:50:38] using /home/ansible/guac-compose-weekly.tar.gz
[12:50:38] backup: /root/pre-compose-backup-2026-11-03-125038.tar.gz
[12:50:38] installed:
    /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml
    /opt/ansible/nucleus/roles/weekly_common/tasks/sign_weekly_images.yml
    /opt/ansible/nucleus/roles/weekly_common/tasks/main.yml
    /opt/ansible/nucleus/roles/weekly_common/tasks/render_weekly_compose.yml
    /opt/ansible/nucleus/roles/configure_guacamole/vars/main.yml
    /opt/ansible/nucleus/roles/configure_guacamole/molecule/guac16/prepare.yml
    /opt/ansible/files/avocado/docker-compose.yml.j2
[12:50:38] ownership set to ansible:ansible-admin
[12:50:38] checks passed
[12:50:38] rendering this week's Guacamole compose files
[WARNING]: Skipping callback plugin 'stig_xml', unable to load

PLAY [Render this week's Guacamole compose files] *******************************************************

TASK [Render] *******************************************************************************************
included: /opt/ansible/nucleus/roles/weekly_common/tasks/render_weekly_compose.yml for localhost

TASK [Weekly compose - database, port and path values from the quarterly build role] ********************
ok: [localhost]

TASK [Weekly compose - this week's Guacamole image versions] ********************************************
ok: [localhost]

TASK [Weekly compose - work out the week folder and versions] *******************************************
ok: [localhost]

TASK [Weekly compose - docker-compose.yml (hardened, nucleus)] ******************************************
changed: [localhost]

TASK [Weekly compose - docker-compose-ccop.yml (functional, ccop, no hardening)] ************************
changed: [localhost]

TASK [Weekly compose - .env] ****************************************************************************
changed: [localhost]

TASK [Weekly compose - not rendered yet] ****************************************************************
skipping: [localhost]

PLAY RECAP **********************************************************************************************
localhost                  : ok=7    changed=3    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0

-rw-rw----. 1 ansible ansible-admin 3185 Nov  3 12:50 /opt/ansible/files/avocado/weekly/45/docker-compose-ccop.yml
-rw-rw----. 1 ansible ansible-admin 3785 Nov  3 12:50 /opt/ansible/files/avocado/weekly/45/docker-compose.yml
-rw-rw----. 1 ansible ansible-admin  156 Nov  3 12:50 /opt/ansible/files/avocado/weekly/45/.env
[12:50:43] image lines:
    image: nucleus/guacd:1.6.0
    image: nucleus/postgres:18.6
    image: nucleus/guacamole:1.6.0
    image: nucleus/nginx:1.31.8
    image: ccop/guacd:1.6.0
    image: ccop/postgres:18.6
    image: ccop/guacamole:1.6.0
    image: ccop/nginx:1.31.8

[12:50:43] done. Next, as ansible:
    /opt/ansible/molecule/run-guac16.sh deploy ccop && /opt/ansible/molecule/run-guac16.sh verify ccop; /opt/ansible/molecule/run-guac16.sh deploy && /opt/ansible/molecule/run-guac16.sh verify



The rm removes the ccop template I’d added to the role, which isn’t used. Retire your old functional template however you like; renaming it to .retired keeps it for reference.

Then, as ansible:

ansible-playbook /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml
ls -l /opt/ansible/files/avocado/weekly/45/docker-compose*.yml /opt/ansible/files/avocado/weekly/45/.env
/opt/ansible/molecule/run-guac16.sh deploy ccop && /opt/ansible/molecule/run-guac16.sh verify ccop; /opt/ansible/molecule/run-guac16.sh deploy && /opt/ansible/molecule/run-guac16.sh verify


If both pass, one run of play_weekly_molecule.sh puts the results on the dashboard.

I’ve assumed the quarterly build role is at /opt/ansible/nucleus/roles/build_guac_release (the name in its defaults comment). If the path differs, it’s one line near the top of render_weekly_compose.yml.
