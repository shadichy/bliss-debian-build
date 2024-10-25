#!/bin/bash

set -e

unset TMP TEMP TMPDIR || true

# might not be exported if we're running from init=/bin/sh or similar
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
DEBOOTSTRAP_DIR=/usr/share/debootstrap
dscriptdir=$DEBOOTSTRAP_DIR/scripts/
this_command=
previous_command=

trap 'previous_command=$this_command; this_command=$BASH_COMMAND' DEBUG

err() { echo -e "ERROR: $* !" && clean && exit 1; }
argerr() { err "Cannot set build to empty"; }
cmderr() { err "Command $previous_command failed"; }
cderr() { err "d build is not found"; }

clean() {
  umount -Rf build
  rm -f $DEBOOTSTRAP_DIR/arch

  rm -f "$dscriptdir/$branch"
  if [ -f "$dscriptdir/$branch.bak" ]; then
    mv "$dscriptdir/$branch.bak" "$dscriptdir/$branch"
  fi

  return 0
}

arch() {
  case "$1" in
  x86_64) echo amd64 ;;
  i?86) echo i386 ;;
  aarch64 | arm64) echo arm64 ;;
  armv*) echo armhf ;;
  *) echo "$1" ;;
  esac
}

# shellcheck disable=SC2068
if (($(id -u) != 0)); then
  if [ "$(command -v sudo)" ]; then
    sudo "$0" $@
  elif [ "$(command -v doas)" ]; then
    doas "$0" $@
  else
    err "Please run this command as root"
  fi
  exit $?
fi

# shellcheck disable=SC2317
exit_check() {
  [ "$1" != 0 ] && cmderr
  exit "$1"
}

trap 'exit_check $?' EXIT

while [[ $1 ]]; do
  case $1 in
  -a | --arch) [ -z "$2" ] && argerr build || arch="$2" ;;
  -m | --mirror) [ -z "$2" ] && argerr build || mirror="$2" ;;
  -b | --branch) [ -z "$2" ] && argerr build || branch="$2" ;;
  -o | --dist) [ -z "$2" ] && argerr build || dist="$2" ;;
  *) break ;;
  esac
  shift 2
done

default_mirror=http://deb.devuan.org
[ -z "$mirror" ] && read -rp "Enter mirror (default: $default_mirror): " mirror
mirror=${mirror:-$default_mirror}

default_branch=excalibur
[ -z "$branch" ] && read -rp "Enter branch (default: $default_branch): " branch
branch=${branch:-$default_branch}

default_arch=$(arch "$(uname -m)")
[ -z "$arch" ] && read -rp "Enter architecture: (default: $default_arch): " arch
arch=${arch:-$default_arch}
export CARCH=$arch

[ "$dist" ] || dist=./dist/installer.sfs
echo "Generate to $dist"

PWD=$(pwd)

rm -rf build dist tmp/upper tmp/work
mkdir -p build dist tmp/upper tmp/work

build_chroot() {
  dd if=/dev/zero of=base.img bs=1M count=1 seek=1024
  mkfs.ext4 base.img

  mount base.img build -o loop

  if [ -f "$dscriptdir/$branch" ]; then
    mv "$dscriptdir/$branch" "$dscriptdir/$branch.bak"
  fi
  sed "s|@mirror@|$mirror/merged|g" scripts/blissos >"$dscriptdir/$branch"

  echo "$arch" >$DEBOOTSTRAP_DIR/arch

  debootstrap \
    --arch "$arch" \
    --variant minbase \
    --merged-usr \
    --verbose \
    --no-check-certificate \
    --no-check-gpg \
    "$branch" build || {
    ls -lA build
    ls -lA build/usr
    ls -lA build/bin
  }
}

if [ -f base.img ]; then
  mount base.img build -o loop,ro
else
  build_chroot
fi

mkdir -p tmp/upper tmp/work tmp/cache

mount overlay build -t overlay -o lowerdir=build,upperdir=tmp/upper,workdir=tmp/work
cp -r template/* build

mount proc build/proc -t proc -o nosuid,noexec,nodev
mount sys build/sys -t sysfs -o nosuid,noexec,nodev,ro
mount udev build/dev -t devtmpfs -o mode=0755,nosuid
mount devpts build/dev/pts -t devpts -o mode=0620,gid=5,nosuid,noexec
mount shm build/dev/shm -t tmpfs -o mode=1777,nosuid,nodev
mount run build/run -t tmpfs -o nosuid,nodev,mode=0755
mount tmp build/tmp -t tmpfs -o mode=1777,strictatime,nodev,nosuid
mount tmp/cache build/var/cache/apt/archives -o bind

# grep 'trusted=yes' build/etc/apt/sources.list || sed -i -r 's|$| [trusted=yes]|g' build/etc/apt/sources.list
echo "deb $mirror/merged $branch main [trusted=yes]" >build/etc/apt/sources.list
chroot build /bin/apt update --allow-unauthenticated
grep -Ev '^#' pkglist.txt | xargs chroot build /bin/apt install -y --no-install-recommends --no-install-suggests --allow-unauthenticated
grep -Ev '^#' rmlist.txt | xargs chroot build /bin/dpkg --remove --force-depends --force-remove-essential || :

for d in \
  bin \
  sbin \
  lib \
  lib32 \
  lib64; do
  if [ -d build/usr/$d ]; then
    ln -s usr/$d tmp/upper
  fi
done

for d in \
  dev \
  sys \
  run \
  proc \
  tmp \
  android \
  boot/grub \
  boot/efi \
  cdrom \
  root; do
  mkdir -p tmp/upper/$d
done

for d in \
  data \
  data_mirror \
  system \
  storage \
  sdcard \
  apex \
  linkerconfig \
  debug_ramdisk \
  system_ext \
  product \
  vendor; do
  ln -s android/$d build
done

echo 'blissos' >build/etc/hostname

cat <<EOF >build/usr/sbin/autologin
#!/bin/sh
exec login -f root
EOF
chmod +x build/usr/sbin/autologin
sed -i 's@1:2345:respawn:/sbin/getty@1:2345:respawn:/sbin/getty -n -l /usr/sbin/autologin@g' build/etc/inittab
sed -i -r 's|^(root:.*:)/bin/d?a?sh$|\1/bin/bash|g' build/etc/passwd

# shellcheck disable=SC2016
echo '[ -z "$DISPLAY" ] && { startx /usr/bin/jwm; poweroff; }' >build/root/.bash_profile
chmod +x build/root/.bash_profile

cp -rn -t tmp/upper/etc \
  build/etc/init.d \
  build/etc/profile \
  build/etc/profile.d \
  build/etc/ld.so.conf \
  build/etc/ld.so.conf.d \
  build/etc/inittab \
  build/etc/rc.local \
  build/etc/rc.shutdown

for d in \
  etc/apt \
  usr/include \
  usr/lib/cmake \
  usr/share/doc \
  usr/share/doc-base \
  usr/share/gtk-doc \
  usr/share/info \
  usr/share/man \
  usr/share/man-db \
  var/cache/* \
  var/lib/apt \
  var/lib/dpkg; do
  rm -rf tmp/upper/"$d"
done

for mnt in \
  var/cache/apt/archives \
  tmp \
  run \
  dev/shm \
  dev/pts \
  dev \
  sys \
  proc \
  /; do
  umount "build/$mnt"
done

for d in libselinux.so.1 libc.so.6 ld-linux-x86-64.so.2; do
  ln -s x86_64-linux-gnu/$d tmp/upper/lib
done

find tmp/upper/usr/{s,}bin -type c -exec rm -f {} +
rm -rf tmp/upper/lib/{firmware,modules}

ln -s /system/lib/modules /vendor/firmware tmp/upper/lib/

chroot tmp/upper /usr/bin/busybox --install -s /bin

chroot tmp/upper /usr/sbin/update-rc.d dbus defaults
chroot tmp/upper /usr/sbin/update-rc.d udev defaults
chroot tmp/upper /usr/sbin/update-rc.d eudev defaults

# find tmp/upper/etc -type c -exec rm -f {} +
find tmp/upper/etc/rc*.d/ -type c | while read -r svc; do
  rsvc=$(echo "$svc" | sed -r 's|.*[SK][0-9]{2}||g')
  [ -f tmp/upper/etc/init.d/"$rsvc" ] || continue
  rm "$svc"
  ln -s ../init.d/"$rsvc" "$svc"
done

clean

mksquashfs tmp/upper "$dist" -comp zstd -Xcompression-level 22 -noappend -no-duplicates -no-recovery -always-use-fragments
