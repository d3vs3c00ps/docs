#!/usr/bin/env bash
# note: linux/boot/grub.md
# env: priv:leap
# grub2-mkconfig needs / on a block device (grub2-probe), which the container's overlay
# is not. So the test copies the container into an ext4 loop image and runs it in a
# chroot there. Fake kernel files stand in for kernel-default. The host boot is never touched.
source "$NOTES_ROOT/tests/lib/assert.sh"

NOTE=linux/boot/grub
R=/mnt/root
zypper -n -q install --no-recommends e2fsprogs >/dev/null

section "Changing the GRUB background image"
install=$(note_block "$NOTE" 'Changing the GRUB' 1 | sed 's/zypper install/zypper -n -q install --no-recommends/')
check "install the branding package (from the note)" bash -ec "$install"
check "theme assets are in /boot/grub2/themes/openSUSE/" test -f /boot/grub2/themes/openSUSE/theme.txt
check_output "the package sets GRUB_THEME" '^GRUB_THEME=/boot/grub2/themes/openSUSE/theme\.txt$' cat /etc/default/grub
check_output "the file already has an empty GRUB_BACKGROUND= line" '^GRUB_BACKGROUND=$' cat /etc/default/grub

truncate -s 2G /root.img
mkfs.ext4 -q /root.img
mkdir -p $R && mount -o loop /root.img $R
cp -ax / $R
for d in dev proc sys; do mount --bind /$d $R/$d; done
kver=6.12.0-160000.40-default
# 10_linux looks for /boot/Image-* on arm64, and /boot/vmlinuz-* on x86_64.
kfile=vmlinuz
[[ $(uname -m) == aarch64 ]] && kfile=Image
touch "$R/boot/$kfile-$kver" "$R/boot/initrd-$kver"
cp $R/boot/grub2/themes/openSUSE/logo.png $R/boot/grub2/themes/openSUSE/my-image.png
note_block "$NOTE" 'Changing the GRUB' 2 >>$R/etc/default/grub
mkconfig=$(note_block "$NOTE" 'Changing the GRUB' 4)
mk() { chroot $R bash -c "$mkconfig" 2>&1; }

out=$(mk)
assert_match "with the theme set, grub2-mkconfig finds the theme" 'Found theme: /boot/grub2/themes/openSUSE/theme\.txt' "$out"
assert_no_match "and ignores GRUB_BACKGROUND" 'Found background' "$out"
check_fails "no background_image in grub.cfg" grep -q background_image $R/boot/grub2/grub.cfg

check "comment out GRUB_THEME (from the note)" chroot $R bash -ec "$(note_block "$NOTE" 'Changing the GRUB' 3)"
out=$(mk)
while IFS= read -r line; do
  # shellcheck disable=SC2001 # a regex escape needs sed
  assert_match "the output has: $line" "^$(sed 's/[.]/\\./g' <<<"$line")\$" "$out"
done < <(note_block "$NOTE" 'Changing the GRUB' 5 | sed "s|/boot/vmlinuz-|/boot/$kfile-|")
assert_no_match "there is no 'Found background image:' line (the correction)" 'Found background image' "$out"
check "grub.cfg loads the image" grep -q 'background_image -m stretch /boot/grub2/themes/openSUSE/my-image\.png' $R/boot/grub2/grub.cfg

cp $R/etc/default/grub /tmp/grub.default
echo 'GRUB_BACKGROUND=/boot/nope.png' >>$R/etc/default/grub
out=$(mk) && rc=0 || rc=$?
assert_eq "a missing file is skipped with no error" 0 "$rc"
assert_no_match "and no Found background line" 'Found background' "$out"
cp $R/boot/grub2/themes/openSUSE/logo.png $R/boot/my-image.bmp
echo 'GRUB_BACKGROUND=/boot/my-image.bmp' >>$R/etc/default/grub
check_fails "another extension stops grub2-mkconfig" chroot $R grub2-mkconfig -o /boot/grub2/grub.cfg
out=$(mk) || true
assert_match "with Unsupported image format" 'Unsupported image format' "$out"
cp /tmp/grub.default $R/etc/default/grub

before=$(md5sum <$R/boot/grub2/grub.cfg)
check "without -o, grub2-mkconfig prints the configuration" bash -c "chroot $R grub2-mkconfig 2>/dev/null | grep -q background_image"
assert_eq "and leaves grub.cfg as it was" "$before" "$(md5sum <$R/boot/grub2/grub.cfg)"

section "UEFI"
zypper -n -q install --no-recommends shim >/dev/null
check_output "shim-install's default config file is /boot/grub2/grub.cfg" '^grub_cfg="/boot/grub2/grub\.cfg"' cat /usr/sbin/shim-install
check_output "the EFI grub.cfg it writes only sources that file" 'source "\\\$\{prefix\}/\$\{grub_cfg_basename\}"' cat /usr/sbin/shim-install

for d in dev proc sys; do umount $R/$d; done
umount $R
