#!/bin/bash
# apply-weekly-save.sh - run as the ansible user on ansible-forge.
# Adds a "save the image" task to the end of weekly_common/tasks/build_image.yml (backup kept).
set -euo pipefail
F=/opt/ansible/nucleus/roles/weekly_common/tasks/build_image.yml
[ -f "$F" ] || { echo "Missing $F"; exit 1; }
grep -q 'save the image for Molecule' "$F" && { echo "Already applied"; exit 0; }
cp -p "$F" "$F.bak-$(date +%F-%H%M)"
cat >> "$F" <<'EOF'

# Keep the image next to this week's scan results so Molecule (and anyone else) can docker load it.
# Written as .part and renamed, so a half-written file is never picked up. A failed save never
# fails the weekly build.
- name: "Weekly build {{ weekly_img.cls }} - save the image for Molecule"
  ansible.builtin.shell: |
    set -o pipefail
    d="{{ weekly_fdir }}/images"
    f="$d/{{ weekly_img.cls }}-{{ weekly_component.image }}-{{ weekly_version }}.tar.gz"
    mkdir -p "$d"
    docker save "{{ weekly_ns }}{{ weekly_img.cls }}/{{ weekly_component.image }}:{{ weekly_version }}" | gzip -c > "$f.part"
    mv "$f.part" "$f"
  args:
    executable: /bin/bash
  changed_when: true
  failed_when: false
EOF
ansible-playbook --syntax-check -i /home/ansible/inventory.ini /opt/ansible/nucleus/playbooks/weekly_builds.yml >/dev/null && echo "syntax ok"
echo "Applied. Next weekly run saves ccop-/nucleus-<image>-<version>.tar.gz under <weekly week dir>/images/"
