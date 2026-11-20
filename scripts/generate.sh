#!/bin/bash
#
# Emits the image's Dockerfile from the image_config env vars in
# .circleci/config.yml. Two stages:
#   python-build  buildpack-deps:<distro> (full, with every -dev library):
#                 compiles the pyenv Pythons and installs their pip packages
#                 and the Terraform apply gate's reviewer venv.
#   final         buildpack-deps:<distro>-scm plus a smaller set of build
#                 libraries; the Python tree is copied in, one layer per
#                 version, so layers download in parallel.
# The full buildpack-deps layer (ImageMagick, GLib, image and database -dev
# libraries, ...) is then needed only to build, not in the published image.

set -e

APT_CLEAN='rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*'
PIP_CLEAN='rm -rf /root/.cache/pip /tmp/*'
NVM_SH='. /root/.nvm/nvm.sh'
PYENV_ROOT_DIR='/opt/circleci/.pyenv'
# Where the build stage leaves the compiled versions, so the final stage can
# copy each one as its own layer.
PYENV_VERSIONS_STAGE='/opt/pyenv-versions'

# Build tools and -dev libraries kept in the final image for jobs that build
# native packages (pip sdists, node-gyp, cgo). gcc/g++/make come with
# build-essential (emit_node). The runtime libraries the copied Pythons link
# against come with these -dev packages, plus libgdbm (dbm.gnu).
BUILD_LIBS='autoconf automake libtool pkg-config patch file xz-utils bzip2
  libssl-dev libffi-dev zlib1g-dev libbz2-dev liblzma-dev libsqlite3-dev
  libreadline-dev libncurses5-dev libgdbm6 libgdbm-compat4 libxml2-dev
  libxslt1-dev libyaml-dev libpq-dev default-libmysqlclient-dev
  libcurl4-openssl-dev'

# Modules each copied Python must import in the final image (shared libraries
# present).
PYTHON_SMOKE_MODULES='ssl, hashlib, sqlite3, readline, bz2, lzma, zlib, ctypes, curses, uuid, dbm.gnu, decimal, json'

has_versions() {
  [ -n "${1:-}" ]
}

first_word() {
  echo "$1" | cut -d' ' -f1
}

distro() {
  awk -F'_' '{print tolower($2)}' <<<"${LINUX_VERSION}"
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

# -- python-build stage ---------------------------------------------------------
emit_python_build_stage() {
  local default_python python_version
  default_python="$(first_word "${PYTHON_VERSION_NUM}")"

  cat <<EOF
FROM buildpack-deps:$(distro) AS python-build
ENV DEBIAN_FRONTEND=noninteractive
ENV PYENV_ROOT=${PYENV_ROOT_DIR}
ENV PATH=${PYENV_ROOT_DIR}/shims:${PYENV_ROOT_DIR}/bin:\$PATH
RUN curl -fsSL https://github.com/pyenv/pyenv-installer/raw/master/bin/pyenv-installer | bash
EOF

  for python_version in ${PYTHON_VERSION_NUM}; do
    cat <<EOF
RUN pyenv install ${python_version} && \\
    rm -rf ${PYENV_ROOT_DIR}/versions/${python_version}/lib/python*/test \\
           ${PYENV_ROOT_DIR}/versions/${python_version}/lib/python*/idle_test \\
           ${PYENV_ROOT_DIR}/versions/${python_version}/lib/python*/lib2to3/tests \\
           ${PYENV_ROOT_DIR}/cache /tmp/*
EOF
  done

  cat <<EOF
RUN pyenv global ${default_python}
EOF

  pip_install -U pip==20.1.1
  emit_ansible

  # terraform-compliance runs on 3.8.5 (run_app_terraform.sh switches to it).
  cat <<EOF
RUN pyenv global 3.8.5 && \\
    pip install --no-cache-dir terraform-compliance && \\
    pyenv global ${default_python} && \\
    ${PIP_CLEAN}
EOF

  emit_tf_plan_review

  cat <<EOF
RUN find ${PYENV_ROOT_DIR}/versions -type d -name '__pycache__' -prune -exec rm -rf {} + && \\
    mv ${PYENV_ROOT_DIR}/versions ${PYENV_VERSIONS_STAGE} && \\
    mkdir ${PYENV_ROOT_DIR}/versions
EOF
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

# The Terraform apply gate's AI reviewer venv (fenderdigital/circleci
# terraform/plan_gate): built once here from its hash-pinned lock, so builds
# don't install it from PyPI each time. The launcher uses it only when the
# .complete marker matches its own requirements.lock (copy of it in
# scripts/tf_plan_review/; keep the two in sync) and the venv's interpreter is
# the Python 3.12 it chose; otherwise it installs its own venv as before.
emit_tf_plan_review() {
  local python_version
  python_version="${TF_PLAN_REVIEW_PYTHON:-$(tr ' ' '\n' <<<"${PYTHON_VERSION_NUM}" | grep -m1 '^3\.12\.' || true)}"
  if [ -z "${python_version}" ]; then
    echo "emit_tf_plan_review: no Python 3.12 in PYTHON_VERSION_NUM" >&2
    return 1
  fi

  cat <<EOF
COPY scripts/tf_plan_review/requirements.lock /opt/tf-plan-review/requirements.lock
RUN ${PYENV_ROOT_DIR}/versions/${python_version}/bin/python3.12 -I -m venv /opt/tf-plan-review/venv && \\
    /opt/tf-plan-review/venv/bin/python -I -m pip install --isolated --no-cache-dir --quiet \\
      --require-hashes --only-binary :all: --no-deps -r /opt/tf-plan-review/requirements.lock && \\
    printf 'lock-%s' "\$(sha256sum /opt/tf-plan-review/requirements.lock | cut -d' ' -f1)" \\
      > /opt/tf-plan-review/venv/.complete && \\
    chmod -R go-w /opt/tf-plan-review && \\
    ${PIP_CLEAN}
EOF
}

# -- final stage ----------------------------------------------------------------
emit_base() {
  cat <<EOF
FROM buildpack-deps:$(distro)-scm
ENV DEBIAN_FRONTEND=noninteractive
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
  apt_install ${BUILD_LIBS}
}

emit_python() {
  local python_version

  cat <<EOF
ENV PYENV_ROOT=${PYENV_ROOT_DIR}
ENV PATH=${PYENV_ROOT_DIR}/shims:${PYENV_ROOT_DIR}/bin:\$PATH
COPY --from=python-build ${PYENV_ROOT_DIR} ${PYENV_ROOT_DIR}
EOF

  for python_version in ${PYTHON_VERSION_NUM}; do
    cat <<EOF
COPY --from=python-build ${PYENV_VERSIONS_STAGE}/${python_version} ${PYENV_ROOT_DIR}/versions/${python_version}
EOF
  done

  cat <<EOF
COPY --from=python-build /opt/tf-plan-review /opt/tf-plan-review
RUN echo 'export PYENV_ROOT="${PYENV_ROOT_DIR}"' >> ~/.bashrc && \\
    echo 'export PATH="\$PYENV_ROOT/shims:\$PYENV_ROOT/bin:\$PATH"' >> ~/.bashrc && \\
    echo 'eval "\$(pyenv init -)"' >> ~/.bashrc && \\
    echo 'eval "\$(pyenv virtualenv-init -)"' >> ~/.bashrc && \\
    pyenv rehash
EOF

  for python_version in ${PYTHON_VERSION_NUM}; do
    cat <<EOF
RUN ${PYENV_ROOT_DIR}/versions/${python_version}/bin/python -c "import ${PYTHON_SMOKE_MODULES}"
EOF
  done

  cat <<EOF
RUN aws --version && ansible --version > /dev/null && \\
    ${PYENV_ROOT_DIR}/versions/3.8.5/bin/terraform-compliance --version > /dev/null && \\
    /opt/tf-plan-review/venv/bin/python -c "import strands, boto3"
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

# Terraform: TF_VERSION_REGEX pins the version (keep it in sync with
# fenderdigital/circleci terraform/install_latest.sh, which every app build
# runs; it then finds that version already installed).
emit_terraform() {
  local tf_spec="latest"
  if [ -n "${TF_VERSION_REGEX:-}" ]; then
    tf_spec="latest:${TF_VERSION_REGEX}"
  fi

  cat <<EOF
RUN git clone https://github.com/kamatama41/tfenv.git /root/.tfenv && \\
    export PATH="/root/.tfenv/bin:\$PATH" && \\
    tfenv install '${tf_spec}' && \\
    tfenv use '${tf_spec}' && \\
    rm -rf /root/.tfenv/test /root/.tfenv/docs /tmp/*
RUN export TFLINT_VERSION=${TFLINT_VERSION} && \\
    curl https://raw.githubusercontent.com/terraform-linters/tflint/\$TFLINT_VERSION/install_linux.sh | bash && \\
    rm -rf /tmp/*
RUN wget https://github.com/tfsec/tfsec/releases/download/${TFSEC_VERSION}/tfsec-linux-amd64 -O /root/.tfenv/bin/tfsec && \\
    chmod +x /root/.tfenv/bin/tfsec
EOF
}

main() {
  emit_python_build_stage

  emit_base
  emit_node
  emit_fender_packages
  emit_python
  emit_golang
  emit_terraform
}

main
