#!/bin/bash
# oem-iso-cfg.sh: NVIDIA's installer runs this inside the new system at the
# end of install (the oem-iso-cfg kernel flag), offline, as root, from
# /cdrom/oemdata. Makes the robot user in place of nooemconfig's nvidia user,
# sets hostname, SSH key, sudo, timezone and Wi-Fi, boots headless, and
# enables robot-firstboot.service to finish setup once the network is up.
set -euxo pipefail
D=/cdrom/oemdata
# shellcheck source=/dev/null
source "$D/robot.env"

id nvidia >/dev/null 2>&1 && userdel -r nvidia 2>/dev/null || true
groups=$(for g in sudo adm dialout video plugdev i2c gpio render audio; do
    getent group "$g" >/dev/null && printf '%s,' "$g"; done)
id "$ROBOT_USER" >/dev/null 2>&1 ||
    useradd -m -s /bin/bash -G "${groups%,}" -p "$PASSWORD_HASH" "$ROBOT_USER"
echo "$ROBOT_USER ALL=(ALL) NOPASSWD: ALL" > "/etc/sudoers.d/90-$ROBOT_USER-nopasswd"
chmod 440 "/etc/sudoers.d/90-$ROBOT_USER-nopasswd"
H=/home/$ROBOT_USER
install -d -m 700 -o "$ROBOT_USER" -g "$ROBOT_USER" "$H/.ssh"
echo "$SSH_PUBKEY" > "$H/.ssh/authorized_keys"
chown "$ROBOT_USER:$ROBOT_USER" "$H/.ssh/authorized_keys"; chmod 600 "$H/.ssh/authorized_keys"

echo "$ROBOT_HOSTNAME" > /etc/hostname
sed -i '/^127\.0\.1\.1/d' /etc/hosts; echo "127.0.1.1 $ROBOT_HOSTNAME" >> /etc/hosts
ln -sf /usr/share/zoneinfo/America/New_York /etc/localtime
echo America/New_York > /etc/timezone

# Open Wi-Fi (the campus network) for first boot; NetworkManager keyfile.
if [ -n "$WIFI_SSID" ]; then
    f="/etc/NetworkManager/system-connections/$WIFI_SSID.nmconnection"
    printf '[connection]\nid=%s\ntype=wifi\nautoconnect=true\n\n[wifi]\nmode=infrastructure\nssid=%s\n\n[ipv4]\nmethod=auto\n\n[ipv6]\nmethod=auto\n' \
        "$WIFI_SSID" "$WIFI_SSID" > "$f"
    chmod 600 "$f"
fi

systemctl set-default multi-user.target
systemctl enable ssh.socket 2>/dev/null || systemctl enable ssh 2>/dev/null || true

install -d -m 700 /var/lib/robot-firstboot
install -m 600 "$D/robot.env" /var/lib/robot-firstboot/robot.env
install -m 755 "$D/robot-firstboot.sh" /usr/local/sbin/robot-firstboot.sh
install -m 644 "$D/robot-firstboot.service" /etc/systemd/system/robot-firstboot.service
systemctl enable robot-firstboot.service
