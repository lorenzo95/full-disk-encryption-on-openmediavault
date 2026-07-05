#!/bin/bash
set -e

################ Configuration ################

MAPPER_NAME=tardis
# update url  /bin/luksunlockhttps and update-initramfs -u -k all
WEBSERVERURL="https://..."
HTTPS_VERIFY=true
SSH_PUBKEY="ssh-ed25519..."
DROPBEAR_PORT=2222
NETWORK_MODE=dhcp        # dhcp or static
NETWORK_INTERFACE=enp3s0
NETWORK_IP=              # static only
NETWORK_NETMASK=         # static only
NETWORK_GATEWAY=         # static only, leave empty for no gateway
NETWORK_DNS=             # static only, leave empty for no dns

################ No changes below this line ################

# Validate config
if [ -z "$SSH_PUBKEY" ] || [ "$SSH_PUBKEY" = "ssh-rsa AAAA..." ]; then
    echo "Error: SSH_PUBKEY not set. Aborting."
    exit 1
fi

if [ -z "$WEBSERVERURL" ]; then
    echo "Error: WEBSERVERURL not set. Aborting."
    exit 1
fi

if [ "$NETWORK_MODE" = "static" ]; then
    if [ -z "$NETWORK_IP" ] || [ -z "$NETWORK_NETMASK" ] || [ -z "$NETWORK_INTERFACE" ]; then
        echo "Error: Static network mode requires NETWORK_IP, NETWORK_NETMASK and NETWORK_INTERFACE. Aborting."
        exit 1
    fi
fi

echo "=== Configuring dropbear authorized_keys ==="
mkdir -p /etc/dropbear/initramfs
echo "$SSH_PUBKEY" > /etc/dropbear/initramfs/authorized_keys
chmod 600 /etc/dropbear/initramfs/authorized_keys

echo "=== Installing dependencies ==="
apt install -y dropbear-initramfs curl openssl uuid pwgen

echo "=== Configuring dropbear options ==="
cat > /etc/dropbear/initramfs/dropbear.conf << EOF
DROPBEAR_OPTIONS="-p ${DROPBEAR_PORT} -s -j -k -I 60 -E"
EOF

echo "=== Configuring initramfs networking ==="
if [ "$NETWORK_MODE" = "dhcp" ]; then
    cat >> /etc/initramfs-tools/initramfs.conf << EOF

DEVICE=${NETWORK_INTERFACE}
IP=dhcp
EOF
else
    HOSTNAME=$(hostname)
    IP_PARAM="${NETWORK_IP}::${NETWORK_GATEWAY}:${NETWORK_NETMASK}:${HOSTNAME}:${NETWORK_INTERFACE}:off"
    if [ -n "$NETWORK_DNS" ]; then
        IP_PARAM="${IP_PARAM}:${NETWORK_DNS}"
    fi
    cat >> /etc/initramfs-tools/initramfs.conf << EOF

DEVICE=${NETWORK_INTERFACE}
IP=${IP_PARAM}
EOF
fi

echo "=== Generating LUKS keyfile ==="
WORKDIR="/tmp/lukskeys"
mkdir -p ${WORKDIR}
chown root:root ${WORKDIR}
chmod 700 ${WORKDIR}
cd ${WORKDIR}

UUID=$(uuid)
PW=$(pwgen -Bcnsy 256 -1 | tr -dc 'A-Za-z0-9-_@#$%^&*()')

touch ${UUID}.lek ${UUID}.lek.enc
chmod 600 ${UUID}.lek ${UUID}.lek.enc

dd if=/dev/urandom bs=1 count=256 > ${UUID}.lek
openssl enc -aes-256-cbc -pbkdf2 -salt -a -in ${UUID}.lek -out ${UUID}.lek.enc -pass pass:"${PW}"

echo "=== Adding keyfile to LUKS ==="
LUKS_DEVICE=$(cryptsetup status ${MAPPER_NAME} | awk '/device:/{print $2}')
if [ -z "$LUKS_DEVICE" ]; then
    echo "Error: Could not find LUKS device for mapper ${MAPPER_NAME}. Is it unlocked and running?"
    exit 1
fi
echo "LUKS device: ${LUKS_DEVICE}"
cryptsetup luksAddKey ${LUKS_DEVICE} ${WORKDIR}/${UUID}.lek

echo "=== Creating luksunlockhttps script ==="
if [ "$HTTPS_VERIFY" = "false" ]; then
    CURL_OPTS="-fsS -k --retry-connrefused --retry 5"
else
    CURL_OPTS="-fsS --retry-connrefused --retry 5"
fi

cat > /bin/luksunlockhttps << EOF
#!/bin/sh -e

if [ \$CRYPTTAB_TRIED -eq "0" ]; then
    sleep 10
fi

DECRYPT_PASSWORD='${PW}'
UUID='${UUID}'
WEBSERVERURL='${WEBSERVERURL}'
ENCKEYFILENAME="\${UUID}.lek.enc"

touch /run/luks.key.enc
chmod 700 /run/luks.key.enc

if curl ${CURL_OPTS} \${WEBSERVERURL}/\${ENCKEYFILENAME} -o /run/luks.key.enc; then
    touch /run/luks.key
    chmod 700 /run/luks.key
    openssl enc -d -aes-256-cbc -pbkdf2 -a -in /run/luks.key.enc -out /run/luks.key -pass pass:"\${DECRYPT_PASSWORD}" >/dev/null 2>&1
    cat /run/luks.key
    rm /run/luks.key /run/luks.key.enc
    exit
fi

/lib/cryptsetup/askpass "Enter password and press ENTER: "
EOF

chmod 700 /bin/luksunlockhttps

echo "=== Installing initramfs hooks ==="
cat > /etc/initramfs-tools/hooks/luksunlockhttps << 'HOOK'
#!/bin/sh
PREREQ=""
prereqs() { echo "$PREREQ"; }
case "$1" in
    prereqs) prereqs; exit 0 ;;
esac

. /usr/share/initramfs-tools/hook-functions

copy_exec /bin/luksunlockhttps /bin/luksunlockhttps
copy_exec /usr/bin/curl /bin/curl
copy_exec /usr/bin/openssl /bin/openssl
copy_exec /bin/chmod /bin/chmod
copy_exec /bin/cat /bin/cat
copy_exec /bin/rm /bin/rm
HOOK

chmod +x /etc/initramfs-tools/hooks/luksunlockhttps

echo "=== Updating crypttab ==="
LUKS_UUID=$(blkid -s UUID -o value ${LUKS_DEVICE})
sed -i "s|${MAPPER_NAME} UUID=${LUKS_UUID} none luks$|${MAPPER_NAME} UUID=${LUKS_UUID} none luks,keyscript=/bin/luksunlockhttps|" /etc/crypttab
cat /etc/crypttab

echo "=== Updating initramfs ==="
update-initramfs -u -k all

echo "=== Done ==="
echo
echo "Copy the encrypted key file to your webserver:"
echo "  File: ${WORKDIR}/${UUID}.lek.enc"
echo
echo "  contents for copy/paste:"
cat ${WORKDIR}/${UUID}.lek.enc
echo
echo "  or rsync directly:"
echo "  rsync ${WORKDIR}/${UUID}.lek.enc user@keyserver:/path/to/webroot/"
echo
echo "Reboot to test. Dropbear listening on port ${DROPBEAR_PORT} as fallback."
echo "If HTTPS unlock fails, SSH in with: ssh -p ${DROPBEAR_PORT} root@<ip>"
echo "Then run: cryptroot-unlock"
