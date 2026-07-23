#!/bin/bash
#
# Emits a Dockerfile on stdout from CircleCI image_config environment variables.
#
# Install and cleanup always share the same RUN layer so Docker does not retain
# apt lists, pip/yarn/nvm/go caches, or other build artifacts.
#

set -e

# ---------------------------------------------------------------------------
# Shared cleanup fragments (inlined into generated RUN layers)
# ---------------------------------------------------------------------------
APT_CLEAN='rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*'
PIP_CLEAN='rm -rf /root/.cache/pip /tmp/*'
NVM_SH='. /root/.nvm/nvm.sh'

# Set by emit_python; used when temporarily switching for terraform-compliance.
DEFAULT_PYTHON_VERSION=''

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

enabled() {
  [ "${1:-}" = "true" ]
}

has_versions() {
  [ -n "${1:-}" ]
}

first_word() {
  echo "$1" | cut -d' ' -f1
}

# apt-get update + install --no-install-recommends + same-layer cleanup.
apt_install() {
  cat <<EOF
RUN apt-get update && \\
    apt-get install -y --no-install-recommends $* && \\
    ${APT_CLEAN}
EOF
}

pip_install() {
  cat <<EOF
RUN pip install --no-cache-dir $* && \\
    ${PIP_CLEAN}
EOF
}

# ---------------------------------------------------------------------------
# Base image
# ---------------------------------------------------------------------------

emit_base() {
  local distro
  distro="$(awk -F'_' '{print tolower($2)}' <<<"${LINUX_VERSION}")"

  cat <<EOF
FROM buildpack-deps:${distro}
ENV DEBIAN_FRONTEND=noninteractive
EOF
}

# ---------------------------------------------------------------------------
# Ruby (optional)
# ---------------------------------------------------------------------------

emit_ruby() {
  has_versions "${RUBY_VERSION_NUM:-}" || return 0

  local series
  series="$(awk -F'.' '{print $1"."$2}' <<<"${RUBY_VERSION_NUM}")"

  cat <<EOF
RUN apt-get update && \\
    apt-get install -y --no-install-recommends libssl-dev && \\
    wget http://ftp.ruby-lang.org/pub/ruby/${series}/ruby-${RUBY_VERSION_NUM}.tar.gz && \\
    tar -xzf ruby-${RUBY_VERSION_NUM}.tar.gz && \\
    cd ruby-${RUBY_VERSION_NUM}/ && \\
    ./configure && \\
    make -j4 && \\
    make install && \\
    cd / && \\
    rm -rf ruby-${RUBY_VERSION_NUM} ruby-${RUBY_VERSION_NUM}.tar.gz && \\
    ruby -v && \\
    ${APT_CLEAN}
EOF
}

# ---------------------------------------------------------------------------
# Node + yarn + serverless (optional)
# ---------------------------------------------------------------------------

emit_node() {
  has_versions "${NODE_VERSIONS_NUM:-}" || return 0

  local default_node node_version
  default_node="$(first_word "${NODE_VERSIONS_NUM}")"

  cat <<EOF
RUN apt-get update && \\
    apt-get install -y --no-install-recommends apt-transport-https ca-certificates curl gnupg && \\
    curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | apt-key add - && \\
    echo 'deb https://dl.yarnpkg.com/debian/ stable main' | tee /etc/apt/sources.list.d/yarn.list && \\
    apt-get update && \\
    apt-get install -y --no-install-recommends build-essential yarn jq && \\
    ${APT_CLEAN}
RUN curl -o- https://raw.githubusercontent.com/creationix/nvm/v0.33.11/install.sh | bash
ENV NVM_DIR=/root/.nvm
EOF

  for node_version in ${NODE_VERSIONS_NUM}; do
    cat <<EOF
RUN ${NVM_SH} && \\
    nvm install ${node_version} && \\
    nvm cache clear && \\
    rm -rf /tmp/*
EOF
  done

  cat <<EOF
RUN ${NVM_SH} && \\
    nvm use ${default_node} && \\
    yarn global add serverless@3.39.0 && \\
    yarn cache clean && \\
    rm -rf /usr/local/share/.cache/yarn /root/.npm /tmp/*
EOF
}

# ---------------------------------------------------------------------------
# Java (optional; no-op on Ubuntu Focal / unlisted releases)
# ---------------------------------------------------------------------------

# Body shared by Ubuntu 14.04 and 16.04 Oracle Java branches (no leading RUN).
oracle_java8_commands() {
  cat <<EOF
apt-get update && \\
    apt-get --force-yes -y install software-properties-common && \\
    echo debconf shared/accepted-oracle-license-v1-1 select true | debconf-set-selections && \\
    echo debconf shared/accepted-oracle-license-v1-1 seen true | debconf-set-selections && \\
    cd /var/tmp/ && \\
    wget -O oracle_java8.deb debian.opennms.org/dists/opennms-23/main/binary-all/oracle-java8-installer_8u131-1~webupd8~2_all.deb && \\
    dpkg -i oracle_java8.deb || echo "ok" && apt-get -f install -yq && \\
    rm -f /var/tmp/oracle_java8.deb && \\
    ${APT_CLEAN}
EOF
}

emit_java() {
  enabled "${JAVA:-}" || return 0

  local oracle
  oracle="$(oracle_java8_commands)"

  cat <<EOF
RUN if [ \$(grep 'VERSION_ID="8"' /etc/os-release) ] ; then \\
    echo "deb http://ftp.debian.org/debian jessie-backports main" >> /etc/apt/sources.list && \\
    apt-get update && apt-get -y install -t jessie-backports openjdk-8-jdk ca-certificates-java && \\
    ${APT_CLEAN} \\
; elif [ \$(grep 'VERSION_ID="9"' /etc/os-release) ] ; then \\
    apt-get update && apt-get -y -q --no-install-recommends install -t stable openjdk-8-jdk ca-certificates-java && \\
    ${APT_CLEAN} \\
; elif [ \$(grep 'VERSION_ID="14.04"' /etc/os-release) ] ; then \\
    ${oracle} \\
; elif [ \$(grep 'VERSION_ID="16.04"' /etc/os-release) ] ; then \\
    ${oracle} \\
; fi
EOF
}

# ---------------------------------------------------------------------------
# Fender toolchain
# ---------------------------------------------------------------------------

emit_fender_packages() {
  apt_install \
    zip unzip rsync parallel tar jq wget curl vim less \
    apt-transport-https groff software-properties-common \
    libffi-dev python3-dev netcat lsb-release
}

emit_python() {
  local default_python python_version
  default_python="$(first_word "${PYTHON_VERSION_NUM}")"
  DEFAULT_PYTHON_VERSION="${default_python}"

  # ENV PATH uses \$PATH so Docker expands it at build time (not the host PATH).
  cat <<EOF
ENV PYENV_ROOT=/opt/circleci/.pyenv
ENV PATH=/opt/circleci/.pyenv/bin/shims:/opt/circleci/.pyenv/bin:\$PATH
RUN curl -fsSL https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer | bash && \\
    echo 'export PYENV_ROOT="/opt/circleci/.pyenv"' >> ~/.bashrc && \\
    echo 'export PATH="\$PYENV_ROOT/bin:\$PYENV_ROOT/bin/shims:\$PATH"' >> ~/.bashrc && \\
    echo 'eval "\$(pyenv init -)"' >> ~/.bashrc && \\
    echo 'eval "\$(pyenv virtualenv-init -)"' >> ~/.bashrc && \\
    bash -i -c "source ~/.bashrc"
EOF

  for python_version in ${PYTHON_VERSION_NUM}; do
    cat <<EOF
RUN pyenv install ${python_version} && \\
    rm -rf /opt/circleci/.pyenv/cache /tmp/*
EOF
  done

  cat <<EOF
RUN pyenv global ${default_python}
EOF

  pip_install -U pip==20.1.1
}

emit_ansible() {
  cat <<EOF
RUN export PYTHONIOENCODING=utf8 && \\
    pip install --no-cache-dir wheel 'setuptools==49.6.0' && \\
    pip install --no-cache-dir 'PyYAML==3.12' --ignore-installed && \\
    pip install --no-cache-dir awscli simplejson boto boto3 botocore 'cffi==1.14.5' six 'cryptography>=2.5' 'ansible==2.8.6' && \\
    pip install --no-cache-dir google_compute_engine && \\
    ${PIP_CLEAN}
EOF
}

emit_golang() {
  cat <<EOF
RUN export GOPATH="/root/gowork${GOVERS}" && \\
    export GOROOT="/usr/local/go${GOVERS}" && \\
    wget https://go.dev/dl/go${GOVERS}.linux-amd64.tar.gz && \\
    tar -xzf go${GOVERS}.linux-amd64.tar.gz && \\
    mv go /usr/local/go${GOVERS} && \\
    rm go${GOVERS}.linux-amd64.tar.gz && \\
    mkdir -p "\$GOPATH" && \\
    export PATH="/usr/local/go${GOVERS}/bin:\$PATH" && \\
    go install golang.org/x/tools/cmd/cover@latest && \\
    go install github.com/mattn/goveralls@latest && \\
    wget -q -O honeymarker https://github.com/honeycombio/honeymarker/releases/download/v0.2.10/honeymarker-linux-amd64 && \\
    echo '6e08038f4587d515856076746ad3a69e67376eddd38d8657f449aad393b95cd8  honeymarker' | sha256sum -c && \\
    chmod 755 ./honeymarker && \\
    mv honeymarker /usr/bin && \\
    go clean -cache -modcache && \\
    rm -rf /root/.cache/go-build /tmp/*
EOF
}

emit_terraform() {
  cat <<EOF
RUN git clone https://github.com/kamatama41/tfenv.git /root/.tfenv && \\
    export PATH="/root/.tfenv/bin:\$PATH" && \\
    tfenv install latest:${TF_VERSION_REGEX:-} && \\
    rm -rf /tmp/*
RUN export TFLINT_VERSION=${TFLINT_VERSION} && \\
    curl https://raw.githubusercontent.com/terraform-linters/tflint/\$TFLINT_VERSION/install_linux.sh | bash && \\
    rm -rf /tmp/*
RUN pyenv global 3.8.5 && \\
    pip install --no-cache-dir terraform-compliance && \\
    pyenv global ${DEFAULT_PYTHON_VERSION} && \\
    ${PIP_CLEAN}
RUN wget https://github.com/tfsec/tfsec/releases/download/${TFSEC_VERSION}/tfsec-linux-amd64 -O /root/.tfenv/bin/tfsec && \\
    chmod +x /root/.tfenv/bin/tfsec
EOF
}

# ---------------------------------------------------------------------------
# Optional clients / browser tooling
# ---------------------------------------------------------------------------

emit_db_clients() {
  if enabled "${MYSQL_CLIENT:-}"; then
    apt_install mysql-client
  fi
  if enabled "${POSTGRES_CLIENT:-}"; then
    apt_install postgresql-client
  fi
}

emit_dockerize() {
  enabled "${DOCKERIZE:-}" || return 0

  local version="v0.6.1"
  cat <<EOF
RUN wget https://github.com/jwilder/dockerize/releases/download/${version}/dockerize-linux-amd64-${version}.tar.gz && \\
    tar -C /usr/local/bin -xzvf dockerize-linux-amd64-${version}.tar.gz && \\
    rm dockerize-linux-amd64-${version}.tar.gz
EOF
}

emit_browsers() {
  enabled "${BROWSERS:-}" || return 0

  cat <<EOF
RUN if [ \$(grep 'VERSION_ID="8"' /etc/os-release) ] ; then \\
    echo "deb http://ftp.debian.org/debian jessie-backports main" >> /etc/apt/sources.list && \\
    apt-get update && apt-get -y install -t jessie-backports xvfb phantomjs && \\
    ${APT_CLEAN} \\
; else \\
    apt-get update && apt-get -y --no-install-recommends install xvfb phantomjs && \\
    ${APT_CLEAN} \\
; fi
ENV DISPLAY=:99
RUN curl --silent --show-error --location --fail --retry 3 --output /tmp/firefox.deb https://s3.amazonaws.com/circle-downloads/firefox-mozilla-build_47.0.1-0ubuntu1_amd64.deb && \\
    echo 'ef016febe5ec4eaf7d455a34579834bcde7703cb0818c80044f4d148df8473bb  /tmp/firefox.deb' | sha256sum -c && \\
    dpkg -i /tmp/firefox.deb || apt-get -f install && \\
    apt-get install -y --no-install-recommends libgtk3.0-cil-dev libasound2 libdbus-glib-1-2 libdbus-1-3 && \\
    rm -rf /tmp/firefox.deb && \\
    ${APT_CLEAN}
RUN curl --silent --show-error --location --fail --retry 3 --output /tmp/google-chrome-stable_current_amd64.deb https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb && \\
    (dpkg -i /tmp/google-chrome-stable_current_amd64.deb || apt-get -fy install) && \\
    rm -rf /tmp/google-chrome-stable_current_amd64.deb && \\
    sed -i 's|HERE/chrome"|HERE/chrome" --disable-setuid-sandbox --no-sandbox|g' \\
      "/opt/google/chrome/google-chrome" && \\
    ${APT_CLEAN}
RUN apt-get update && \\
    apt-get install -y --no-install-recommends libgconf-2-4 && \\
    curl --silent --show-error --location --fail --retry 3 --output /tmp/chromedriver_linux64.zip "http://chromedriver.storage.googleapis.com/2.33/chromedriver_linux64.zip" && \\
    cd /tmp && \\
    unzip chromedriver_linux64.zip && \\
    rm -rf chromedriver_linux64.zip && \\
    mv chromedriver /usr/local/bin/chromedriver && \\
    chmod +x /usr/local/bin/chromedriver && \\
    ${APT_CLEAN}
EOF
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  emit_base
  emit_ruby
  emit_node
  emit_java

  emit_fender_packages
  emit_python
  emit_ansible
  emit_golang
  emit_terraform

  emit_db_clients
  emit_dockerize
  emit_browsers
}

main
