# Build tools for the xx50 kernel (armv7 cross compiler, mkimage, dtc) and
# for the card image (sfdisk, mkfs.vfat, mtools). The rootfs itself builds
# in an armv7 Alpine container.
FROM debian:trixie
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      gcc-arm-linux-gnueabihf binutils-arm-linux-gnueabihf build-essential \
      bc bison flex libssl-dev libelf-dev cpio xz-utils zstd kmod \
      u-boot-tools device-tree-compiler python3 git ca-certificates file rsync \
      fdisk dosfstools mtools gzip e2fsprogs \
    && rm -rf /var/lib/apt/lists/*
ENV ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf-
WORKDIR /work
