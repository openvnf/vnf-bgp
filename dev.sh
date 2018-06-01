#!/bin/sh

echo "Installing development and troublshooting tools..."

apk update && apk --no-cache upgrade
apk --no-cache add iproute2 iputils ldns-tools socat \
    strace supervisor tcpdump busybox-extras \
    wget vim
