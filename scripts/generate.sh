#!/bin/bash

set -e

APT_CLEAN='rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*'
PIP_CLEAN='rm -rf /root/.cache/pip /tmp/*'
NVM_SH='. /root/.nvm/nvm.sh'
DEFAULT_PYTHON_VERSION=''

has_versions() {
  [ -n "${1:-}" ]
}

first_word() {
  echo "$1" | cut -d' ' -f1
}

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

emit_base() {
  local distro
  distro="$(awk -F'_' '{print tolower($2)}' <<<"${LINUX_VERSION}")"

  cat <<EOF
FROM buildpack-deps:${distro}
ENV DEBIAN_FRONTEND=noninteractive
EOF
}

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

  cat <<EOF
ENV PYENV_ROOT=/opt/circleci/.pyenv
ENV PATH=/opt/circleci/.pyenv/shims:/opt/circleci/.pyenv/bin:\$PATH
RUN curl -fsSL https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer | bash && \\
    echo 'export PYENV_ROOT="/opt/circleci/.pyenv"' >> ~/.bashrc && \\
    echo 'export PATH="\$PYENV_ROOT/shims:\$PYENV_ROOT/bin:\$PATH"' >> ~/.bashrc && \\
    echo 'eval "\$(pyenv init -)"' >> ~/.bashrc && \\
    echo 'eval "\$(pyenv virtualenv-init -)"' >> ~/.bashrc && \\
    bash -i -c "source ~/.bashrc"
EOF

  for python_version in ${PYTHON_VERSION_NUM}; do
    cat <<EOF
RUN pyenv install ${python_version} && \\
    rm -rf /opt/circleci/.pyenv/versions/${python_version}/lib/python*/test \\
           /opt/circleci/.pyenv/versions/${python_version}/lib/python*/idle_test \\
           /opt/circleci/.pyenv/versions/${python_version}/lib/python*/lib2to3/tests \\
           /opt/circleci/.pyenv/cache /tmp/*
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
    find /opt/circleci/.pyenv/versions -type d -name '__pycache__' -prune -exec rm -rf {} + && \\
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
    rm -rf /usr/local/go${GOVERS}/test \\
           /usr/local/go${GOVERS}/api \\
           /usr/local/go${GOVERS}/doc \\
           /usr/local/go${GOVERS}/misc \\
           /root/.cache/go-build /tmp/*
EOF
}

emit_terraform() {
  local tf_spec="latest"
  if [ -n "${TF_VERSION_REGEX:-}" ]; then
    tf_spec="latest:${TF_VERSION_REGEX}"
  fi

  cat <<EOF
RUN git clone https://github.com/kamatama41/tfenv.git /root/.tfenv && \\
    export PATH="/root/.tfenv/bin:\$PATH" && \\
    tfenv install ${tf_spec} && \\
    tfenv use ${tf_spec} && \\
    rm -rf /root/.tfenv/test /root/.tfenv/docs /tmp/*
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

main() {
  emit_base
  emit_ruby
  emit_node

  emit_fender_packages
  emit_python
  emit_ansible
  emit_golang
  emit_terraform
}

main
