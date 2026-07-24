#!/bin/sh

echo "CircleCI Docker Wizard"

read -r -p "
Name your image (no spaces please!): " IMAGE_NAME

perl -i -pe "s/# name your image \(no spaces please!\)/$IMAGE_NAME/" .circleci/config.yml
perl -i -pe "s/\(name of image\)/$IMAGE_NAME/" .circleci/config.yml

read -r -p "
Give your image a tag (no spaces please!): " IMAGE_TAG

perl -i -pe "s/# give your image a tag \(no spaces please!\)/$IMAGE_TAG/" .circleci/config.yml
perl -i -pe "s/\(image tag\)/$IMAGE_TAG/" .circleci/config.yml

read -r -p "
Pick a Linux version for your image:
  1. Debian 8 (Jessie)
  2. Debian 9 (Stretch)
  3. Ubuntu 14.04 (Trusty)
  4. Ubuntu 16.04 (Xenial)
(Enter 1, 2, 3, or 4): " LINUX_VERSION

case "$LINUX_VERSION" in
  1)
    perl -i -pe 's/# DEBIAN_JESSIE, DEBIAN_STRETCH, UBUNTU_TRUSTY, or UBUNTU_XENIAL/DEBIAN_JESSIE/' .circleci/config.yml
    ;;
  2)
    perl -i -pe 's/# DEBIAN_JESSIE, DEBIAN_STRETCH, UBUNTU_TRUSTY, or UBUNTU_XENIAL/DEBIAN_STRETCH/' .circleci/config.yml
    ;;
  3)
    perl -i -pe 's/# DEBIAN_JESSIE, DEBIAN_STRETCH, UBUNTU_TRUSTY, or UBUNTU_XENIAL/UBUNTU_TRUSTY/' .circleci/config.yml
    ;;
  4)
    perl -i -pe 's/# DEBIAN_JESSIE, DEBIAN_STRETCH, UBUNTU_TRUSTY, or UBUNTU_XENIAL/UBUNTU_XENIAL/' .circleci/config.yml
    ;;
esac

read -r -p "
Pick a Ruby version from https://cache.ruby-lang.org/pub/ruby (i.e., 2.4.2, etc.), or hit enter to skip installing Ruby
: " RUBY_VERSION_NUM

if [ "$RUBY_VERSION_NUM" ] ; then
  perl -i -pe "s/# pick a version from https:\/\/cache.ruby-lang.org\/pub\/ruby/$RUBY_VERSION_NUM/" .circleci/config.yml
else
  perl -i -pe "s/RUBY_VERSION_NUM:/# RUBY_VERSION_NUM:/" .circleci/config.yml
  perl -i -pe "s/- run: ruby/# - run: ruby/" .circleci/config.yml
fi

read -r -p "
Pick a Node version from https://nodejs.org/dist, or hit enter to skip installing Node
: " NODE_VERSION_NUM

if [ "$NODE_VERSION_NUM" ] ; then
  perl -i -pe "s/# pick a version from https:\/\/nodejs.org\/dist/$NODE_VERSION_NUM/" .circleci/config.yml
else
  perl -i -pe "s/NODE_VERSION_NUM:/# NODE_VERSION_NUM:/" .circleci/config.yml
  perl -i -pe "s/- run: node/# - run: node/" .circleci/config.yml
fi

read -r -p "
Pick a Python version from https://python.org/ftp/python, or hit enter to skip installing Python
: " PYTHON_VERSION_NUM

if [ "$PYTHON_VERSION_NUM" ] ; then
  perl -i -pe "s/# pick a version from https:\/\/python.org\/ftp\/python/$PYTHON_VERSION_NUM/" .circleci/config.yml
else
  perl -i -pe "s/PYTHON_VERSION_NUM:/# PYTHON_VERSION_NUM:/" .circleci/config.yml
  perl -i -pe "s/- run: python/# - run: python/" .circleci/config.yml
fi

echo "
Your config.yml is done! Push your changes to GitHub to start building your docker image on CircleCI
"
