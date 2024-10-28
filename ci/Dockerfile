# syntax=docker/dockerfile:1-labs
FROM devuan/migrated:excalibur-slim

COPY . /

# Update packages
RUN apt update && apt upgrade -y

# Install debootstrap
RUN yes | apt install debootstrap bash || :

USER root
RUN --security=insecure env NOLOOP=1 ./build.sh -a amd64 -b excalibur -m https://gnlug.org/pub/devuan -o install.sfs
