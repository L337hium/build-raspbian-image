#!/bin/bash
#set -x

# Usage:
#	./build_pi_image.sh [--profil default] [--device /dev/mmcblk0]
#
#

# Copyright notices
# Refactorying
#
##
### Set runtime enviroment and do initial tests
##
#
export LC_ALL="C"

. ./error_codes.sh


# TODO: Implement debug and verbose option
VERBOSE=1
DEBUG=1


. shflags-1.0.3/src/shflags

set -e

# TEST: Run as root
if [[ ${EUID} -ne 0 ]]; then
	[ "${DEBUG}" ]		&& echo "Error: ${0} have to be run as root."
	[ "${VERBOSE}" ]	&& echo "Abort. Error-Code: ${ERR_USER_IS_NOT_ROOT}"
	exit ${ERR_USER_IS_NOT_ROOT}
fi


# TEST: Dependencies
DEPENDENCIES="binfmt-support qemu qemu-user-static debootstrap kpartx lvm2 dosfstools apt-cacher-ng"
EXIT=0
for TOOL in $DEPENDENCIES; do
	dpkg -l | grep "$TOOL" | grep "^ii" > /dev/null
	if [ $? -ne 0 ]; then
		[ "${DEBUG}" ]		&& echo "Error: Missing dependency: $TOOL"
		EXIT=1
	fi
done
if [ ${EXIT} -eq 1 ]; then
	[ "${VERBOSE}" ]		&& echo "Abort. Error-Code: ${ERR_MISSING_DEPENDENCIES}"
	exit ${ERR_MISSING_DEPENDENCIES}
fi


set +e
# Process given command line arguments and options
DEFINE_string 'profile' 'default' 'name of profile to apply' p
DEFINE_string 'device' '' 'path the block-device' d

FLAGS "$@" || exit $?

eval set -- "${FLAGS_ARGV}"

PROFILE="${FLAGS_profile}"
DEVICE="${FLAGS_device}"

#######################################
set -e
# TEST: Existance of block device, if specified

if ! [ -z "${DEVICE}" ]; then

	if ! [ -b "${DEVICE}" ]; then
		[ "${DEBUG}" ]		&& echo "Error: ${DEVICE} is not a block device or is not found."
		[ "${VERBOSE}" ]	&& echo "Abort. Error-Code: ${ERR_BLOCK_DEVICE_IS_NOT_FOUND}"
		exit ${ERR_BLOCK_DEVICE_IS_NOT_FOUND}
	fi

else

	DEVICE=""
fi

[ "${VERBOSE}" ] &&
	if [ "${DEVICE}" ]; then
		echo "Write on device: ${DEVICE}"
	else
		echo "Write to disk image."
	fi

# TEST: Existance of profiles, if specified
if ! [ -z "${PROFILE}" ]; then

	if ! [ -e "./profiles/${PROFILE}" ]; then 
		[ "${DEBUG}" ]		&& echo "Error: ${PROFILE} was not found under ./profiles/."
		[ "${VERBOSE}" ]	&& echo "Abort. Error-Code: ${ERR_PROFILE_IS_NOT_FOUND}"
		exit ${ERR_PROFILE_IS_NOT_FOUND}
	fi

else

	PROFILE="default"
fi
[ "${VERBOSE}" ] && echo "Apply settings from profile: ${PROFILE}"

#
### Finished all esential tests
#######################################

########################################
# Load available settings/options
. "./settings.sh"
# Overwrite variables with profile settings
. "./profiles/${PROFILE}"

#######################################
## Prepare bootstrap env

relative_path=`dirname $0`

# locate path of this script
absolute_path=`cd ${relative_path}; pwd`

# locate path of delivery content
# delivery_path=`cd ${absolute_path}/delivery; pwd`

# define destination folder where created image file will be stored
buildenv=`cd ${absolute_path}; mkdir -p rpi/images; cd rpi; pwd`
# buildenv="/tmp/rpi"

cd ${absolute_path}


rootfs="${buildenv}/rootfs"
bootfs="${rootfs}/boot"

BUILD_TIME="$(date +%Y%m%d-%H%M%S)"

IMAGE_PATH=""

# if no block device was given, create image
if [ "${DEVICE}" = "" ]; then
	mkdir -p ${buildenv}
	IMAGE_PATH="${buildenv}/images/${PROFILE}-${BUILD_TIME}.img"
	dd if=/dev/zero of=${IMAGE_PATH} bs=1MB count=1800		# TODO: Decrease value or shrink at the end
	DEVICE=$(losetup -f --show ${IMAGE_PATH})

	[ ${VERBOSE} ] && echo "Image ${IMAGE_PATH} created and mounted as ${DEVICE}."
else
	dd if=/dev/zero of=${DEVICE} bs=512 count=1

	[ ${VERBOSE} ] && echo "Ereased block device ${DEVICE}."
fi

# Create partions
set +e
fdisk ${DEVICE} << EOF
n
p
1

+${_BOOT_PARTITION_SIZE}
t
c
n
p
2


w
EOF

# Find partions on block device or in image file
if [ "${IMAGE_PATH}" != "" ]; then
	losetup -d ${DEVICE}
	DEVICE=`kpartx -va ${IMAGE_PATH} | sed -E 's/.*(loop[0-9])p.*/\1/g' | head -1`
	DEVICE="/dev/mapper/${DEVICE}"
	bootp=${DEVICE}p1
	rootp=${DEVICE}p2
else
	if ! [ -b ${DEVICE}1 ]; then
		bootp=${DEVICE}p1
		rootp=${DEVICE}p2
		if ! [ -b ${bootp} ]; then
			[ "${DEBUG}" ]		&& echo "Error: Can't find boot partition neither as ${DEVICE}1 nor as ${DEVICE}p1."
			[ "${VERBOSE}" ]	&& echo "Abort. Error-Code: $ERR_NO_BOOT_PARTITION_FOUND"
			exit $ERR_NO_BOOT_PARTITION_FOUND
		fi
	else
		bootp=${DEVICE}1
		rootp=${DEVICE}2
	fi
fi

mkfs.vfat ${bootp}
mkfs.ext4 ${rootp}

#######################################

set -e

mkdir -p ${rootfs}

mount ${rootp} ${rootfs}

mkdir -p ${rootfs}/proc
mkdir -p ${rootfs}/sys
mkdir -p ${rootfs}/dev
mkdir -p ${rootfs}/dev/pts
#mkdir -p ${rootfs}/usr/src/delivery

mount -t proc none ${rootfs}/proc
mount -t sysfs none ${rootfs}/sys
mount -o bind /dev ${rootfs}/dev
mount -o bind /dev/pts ${rootfs}/dev/pts
#mount -o bind ${delivery_path} ${rootfs}/usr/src/delivery

cd ${rootfs}

#######################################
# Start installation of base system
#debootstrap --arch armhf --variant=minbase --no-check-gpg --foreign ${_DEB_RELEASE} ${rootfs} $(get_apt_source_mirror_url)
debootstrap --arch armhf --no-check-gpg --foreign ${_DEB_RELEASE} ${rootfs} $(get_apt_source_mirror_url)


# Complete installation process
cp /usr/bin/qemu-arm-static usr/bin/
LANG=C chroot ${rootfs} /debootstrap/debootstrap --second-stage

mount ${bootp} ${bootfs}

# Prevent services from starting during installation.
echo "#!/bin/sh
exit 101
EOF" > usr/sbin/policy-rc.d
chmod +x usr/sbin/policy-rc.d


# etc/apt/sources.list
get_apt_sources_first_stage > etc/apt/sources.list

# boot/cmdline.txt
echo "dwc_otg.lpm_enable=0 console=ttyAMA0,115200 kgdboc=ttyAMA0,115200 console=tty1 root=/dev/mmcblk0p2 rootfstype=ext4 rootwait" > boot/cmdline.txt

# etc/fstab
echo "${_FSTAB}" > etc/fstab

# etc/hostname
echo "${_HOSTNAME}" > etc/hostname


# etc/network/interfaces
set_network_config ${_NET_CONFIG}


# etc/modules
echo "vchiq
snd_bcm2835
bcm2708-rng
" >> etc/modules

# debconf.set
echo "console-common	console-data/keymap/policy	select	Select keymap from full list
console-common	console-data/keymap/full	select	${_KEYMAP}
" > debconf.set

## Write first boot script
echo "#!/bin/bash
# This script will run the first time the raspberry pi boots.
# It is ran as root.

echo "$(date) Starting firstboot.sh" >> /dev/kmsg

echo "$(date) Reconfiguring openssh-server" >> /dev/kmsg
echo "$(date)   Collecting entropy" >> /dev/kmsg
# Drain entropy pool to get rid of stored entropy after boot.
dd if=/dev/urandom of=/dev/null bs=1024 count=10 2>/dev/null

while entropy=\$(cat /proc/sys/kernel/random/entropy_avail)
  (( \$entropy < 200 ))
do sleep 1
done

rm -f /etc/ssh/ssh_host_*
#echo 'Generating SSH host keys ...'
dpkg-reconfigure openssh-server
echo "$(date) Reconfigured openssh-server" >> /dev/kmsg


# Set locale
export LANGUAGE=${_LOCALES}.${_ENCODING}
export LANG=${_LOCALES}.${_ENCODING}
export LC_ALL=${_LOCALES}.${_ENCODING}
cat << EOF | debconf-set-selections
locales   locales/locales_to_be_generated multiselect     ${_LOCALES}.${_ENCODING} ${_ENCODING}
EOF
rm /etc/locale.gen
dpkg-reconfigure -f noninteractive locales
update-locale LANG="${_LOCALES}.${_ENCODING}"
cat << EOF | debconf-set-selections
locales   locales/default_environment_locale select       ${_LOCALES}.${_ENCODING}
EOF
echo "$(date) Reconfigured locale" >> /dev/kmsg

# Set timezone
echo "${_TIMEZONE}" > /etc/timezone
dpkg-reconfigure -f noninteractive tzdata
#echo '$(date) Reconfigured timezone' >> /var/log/first_boot.log
echo "$(date) Reconfigured timezone" >> /dev/kmsg

# Expand filesystem
raspi-config --expand-rootfs
echo '$(date) Expand rootfs done' >> /dev/kmsg

sleep 5

reboot

" > root/firstboot.sh
chmod 755 root/firstboot.sh

######################################
# enable login on serial console
#echo "T0:23:respawn:/sbin/getty -L ttyAMA0 115200 vt100" > etc/inittab

#######################################
echo "#!/bin/bash
debconf-set-selections /debconf.set
rm -f /debconf.set

#cd /usr/src/delivery


apt-get update
apt-get install --reinstall language-pack-en

apt-get -y install aptitude gpgv git-core binutils ca-certificates wget curl # TODO FIXME

gpg --keyserver pgpkeys.mit.edu --recv-key 8B48AD6246925553
gpg -a --export 8B48AD6246925553 | apt-key add -

wget -q http://archive.raspberrypi.org/debian/raspberrypi.gpg.key -O - | apt-key add -

curl -L --output /usr/bin/rpi-update https://raw.github.com/Hexxeh/rpi-update/master/rpi-update && chmod +x /usr/bin/rpi-update
touch /boot/start.elf
mkdir -p /lib/modules
SKIP_BACKUP=1 /usr/bin/rpi-update

apt-get -y install ${_APT_PACKAGES} # FIXME

rm -f /etc/ssh/ssh_host_*

apt-get -y install lua5.1 triggerhappy
apt-get -y install dmsetup libdevmapper1.02.1 libparted0debian1 parted
wget http://archive.raspberrypi.org/debian/pool/main/r/raspi-config/raspi-config_20131216-1_all.deb
dpkg -i raspi-config_20131216-1_all.deb
rm -f raspi-config_20131216-1_all.deb

apt-get -y install rng-tools

#cp /usr/share/doc/raspi-config/sample_profile_d.sh /etc/profile.d/raspi-config.sh
#chmod 755 /etc/profile.d/raspi-config.sh

# execute install script at mounted external media (delivery contents folder)
#cd /usr/src/delivery
#./install.sh
#cd /usr/src/delivery

echo \"${_USER_NAME}:${_USER_PASS}\" | chpasswd
sed -i -e 's/KERNEL\!=\"eth\*|/KERNEL\!=\"/' /lib/udev/rules.d/75-persistent-net-generator.rules
rm -f /etc/udev/rules.d/70-persistent-net.rules
rm -f third-stage
" > third-stage
chmod +x third-stage

LANG=C chroot ${rootfs} /third-stage

###################
echo "#!/bin/sh -e
if [ ! -e /root/firstboot_done ]; then
	if [ -e /root/firstboot.sh ]; then
		/root/firstboot.sh
	fi
	touch /root/firstboot_done
fi

exit 0
" > etc/rc.local

###################
# write apt source list again
get_apt_sources_final_stage > etc/apt/sources.list

###################
# cleanup
echo "#!/bin/bash
aptitude update
aptitude clean
apt-get clean
rm -f /etc/ssl/private/ssl-cert-snakeoil.key
rm -f /etc/ssl/certs/ssl-cert-snakeoil.pem
rm -f /var/lib/urandom/random-seed
rm -f /usr/sbin/policy-rc.d
rm -f cleanup
" > cleanup
chmod +x cleanup
LANG=C chroot ${rootfs} /cleanup

cd ${rootfs}

sync

sleep 30
set +e

# Kill processes still running in chroot.
for rootpath in /proc/*/root; do
    rootlink=$(readlink $rootpath)
    if [ "x${rootlink}" != "x" ]; then
        if [ "x${rootlink:0:${#rootfs}}" = "x${rootfs}" ]; then
            # this process is in the chroot...
            PID=$(basename $(dirname "$rootpath"))
            kill -9 "$PID"
        fi
    fi
done

umount -l ${bootp}

#umount -l ${rootfs}/usr/src/delivery
umount -l ${rootfs}/dev/pts
umount -l ${rootfs}/dev
umount -l ${rootfs}/sys
umount -l ${rootfs}/proc

umount -l ${rootfs}
umount -l ${rootp}

[ "${VERBOSE}" ]		&& echo "Finishing ${IMAGE_PATH}."

sync
sleep 5

if [ "${IMAGE_PATH}" != "" ]; then
	kpartx -vd ${IMAGE_PATH}
	# [ "${VERBOSE}" ]		&& echo "Created image ${IMAGE_PATH}."
fi

[ "${VERBOSE}" ]		&& echo "Done." # TODO

exit ${SUCCESS}
