FROM devuan/migrated:excalibur-slim

COPY . /

# Update packages
RUN apt update && apt upgrade -y

# Install debootstrap
RUN  apt install -y debootstrap bash

RUN ./build.sh -a amd64 -b ceres -m https://gnlug.org/pub/devuan -o install.sfs
