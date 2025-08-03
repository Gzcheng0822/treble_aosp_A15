FROM ubuntu:24.04 AS base

USER root

ARG DEBIAN_FRONTEND=noninteractive
RUN dpkg --add-architecture i386 && \
    apt update && \
    apt upgrade -y && \
    apt install -y aapt android-sdk-libsparse-utils bc bison build-essential curl dos2unix flex fontconfig \
                   g++-multilib gcc-multilib git gnupg gperf imagemagick jq lib32z1-dev libc6-dev-i386 \
                   libelf-dev libgl1-mesa-dev libncurses-dev libssl-dev libstdc++6 libx11-dev libxml2-utils \
                   locales lunzip lzip lzop m4 make nano openjdk-17-jdk python-is-python3 python3-pip \
                   rsync squashfs-tools sudo tree unzip wget x11proto-core-dev xattr xmlstarlet xsltproc \
                   zip zlib1g-dev && \
    apt clean -y && \
    apt autoremove -y && \
    rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8 && \
    dpkg-reconfigure locales

RUN curl -sfL https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo && \
    chmod +x /usr/local/bin/repo

RUN curl -sfL https://packagecloud.io/install/repositories/github/git-lfs/script.deb.sh | bash && \
    apt install -y git-lfs

USER ubuntu
WORKDIR /work

COPY --chown=ubuntu:ubuntu . /work/treble_aosp

RUN git lfs install && \
    git config --global alias.pushfwl "push --force-with-lease" && \
    git config --global color.ui auto && \
    git config --global core.editor "nano" && \
    git config --global push.autoSetupRemote true && \
    git config --global rebase.autosquash true && \
    git config --global user.name "Alberto Ponces" && \
    git config --global user.email ponces26@gmail.com

FROM base AS treblebuild

ENTRYPOINT [ "/work/treble_aosp/build.sh" ]

FROM base AS treblesync

ENTRYPOINT [ "/work/treble_aosp/sync.sh" ]
