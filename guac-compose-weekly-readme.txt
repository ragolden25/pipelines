tar -czf /root/pre-compose-backup-$(date +%F).tar.gz -C / opt/ansible/files/avocado/docker-compose.yml.j2 opt/ansible/nucleus/roles/weekly_common/tasks opt/ansible/nucleus/roles/configure_guacamole/vars opt/ansible/nucleus/roles/configure_guacamole/molecule/guac16/prepare.yml
tar -xzf /home/ansible/guac-compose-weekly.tar.gz -C /
rm -f /opt/ansible/nucleus/roles/configure_guacamole/templates/docker-compose-ccop.yml.j2
chown -R ansible:ansible-admin /opt/ansible/files/avocado/docker-compose.yml.j2 /opt/ansible/nucleus/roles/weekly_common /opt/ansible/nucleus/roles/configure_guacamole /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml


The rm removes the ccop template I’d added to the role, which isn’t used. Retire your old functional template however you like; renaming it to .retired keeps it for reference.

Then, as ansible:

ansible-playbook /opt/ansible/nucleus/playbooks/render_weekly_compose_now.yml
ls -l /opt/ansible/files/avocado/weekly/45/docker-compose*.yml /opt/ansible/files/avocado/weekly/45/.env
/opt/ansible/molecule/run-guac16.sh deploy ccop && /opt/ansible/molecule/run-guac16.sh verify ccop; /opt/ansible/molecule/run-guac16.sh deploy && /opt/ansible/molecule/run-guac16.sh verify


If both pass, one run of play_weekly_molecule.sh puts the results on the dashboard.

I’ve assumed the quarterly build role is at /opt/ansible/nucleus/roles/build_guac_release (the name in its defaults comment). If the path differs, it’s one line near the top of render_weekly_compose.yml.
