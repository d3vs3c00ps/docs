---
title: GRUB
description: Setting a custom GRUB background image on openSUSE Leap
tags: [linux, boot, grub, opensuse]
type: howto
status: complete
---

# GRUB

## Changing the GRUB background image

> [!note] SUSE puts GRUB under `grub2`
> On openSUSE and the RHEL family the generated config is
> `/boot/grub2/grub.cfg` and the regeneration command is `grub2-mkconfig`.
> Debian's `update-grub` wrapper and its `/boot/grub/grub.cfg` path do not
> exist here. The `GRUB_BACKGROUND` setting itself is generic.

This applies to systems that boot with GRUB 2. A system that boots with
systemd-boot does not read `/etc/default/grub` at all.

The background is normally supplied by the branding theme, which is already
installed:

```bash
zypper install grub2-branding-openSUSE
```

Theme assets live in `/boot/grub2/themes/openSUSE/`. Put your own image
somewhere readable at boot. Staying under `/boot` avoids any question of
whether GRUB can reach the filesystem.

Then point GRUB at it in `/etc/default/grub`. The file already has an empty
`GRUB_BACKGROUND=` line: edit that line, or add this one at the end (the file is
read as shell, so the last value wins):

```bash
GRUB_BACKGROUND=/boot/grub2/themes/openSUSE/my-image.png
```

> [!warning] A theme overrides `GRUB_BACKGROUND`
> If `GRUB_THEME` is set, the theme's own background wins and your image is
> ignored. `grub2-mkconfig` then does not even look at `GRUB_BACKGROUND`. The
> branding package sets `GRUB_THEME` when it is installed. Either edit the
> theme's `theme.txt`, or comment out `GRUB_THEME` to fall back to plain
> `GRUB_BACKGROUND`:
>
> ```bash
> sed -i 's/^GRUB_THEME=/#GRUB_THEME=/' /etc/default/grub
> ```

Regenerate the GRUB configuration:

```bash
grub2-mkconfig -o /boot/grub2/grub.cfg
```

If it worked, the output acknowledges the background (on arm64 the kernel is
`/boot/Image-<version>`):

```text
Generating grub configuration file ...
Found background: /boot/grub2/themes/openSUSE/my-image.png
Found linux image: /boot/vmlinuz-6.12.0-160000.40-default
Found initrd image: /boot/initrd-6.12.0-160000.40-default
done
```

> [!note] `Found background:`
> openSUSE prints `Found background:` only. `Found background image:` comes from a
> Debian-only script. With a theme set, it prints `Found theme:` instead.

If the `Found background` line is missing, check the path: a missing file is
skipped with no error. The format must be PNG, JPEG or TGA, and the file name
must end in `.png`, `.jpg`, `.jpeg` or `.tga`. Any other extension stops
`grub2-mkconfig` with `Unsupported image format`.

> [!warning] On UEFI, regenerate the same file
> On openSUSE, `shim-install` writes `/boot/efi/EFI/opensuse/grub.cfg` as a small stub
> that loads `/boot/grub2/grub.cfg`. RHEL 9 and later do the same. So the command
> above is right on UEFI too. Writing the full configuration over the stub breaks it;
> RHEL's `grub2-mkconfig` warns when you try. To inspect the output first, run
> `grub2-mkconfig` without `-o`: it prints the configuration and changes nothing.

<!-- uplink -->
Part of [[linux/boot/index|Boot and init]].
