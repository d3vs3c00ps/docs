# The disk layout, for disko: GPT, a 512 MB EFI system partition, ext4 for the rest.
# /dev/vda is the first disk of a QEMU VM. On a real machine, use a stable name
# from /dev/disk/by-id/, so the install cannot pick the wrong disk.
{
  disko.devices.disk.main = {
    type = "disk";
    device = "/dev/vda";
    content = {
      type = "gpt";
      partitions = {
        ESP = {
          size = "512M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "umask=0077" ];
          };
        };
        root = {
          size = "100%";
          content = {
            type = "filesystem";
            format = "ext4";
            mountpoint = "/";
          };
        };
      };
    };
  };
}
