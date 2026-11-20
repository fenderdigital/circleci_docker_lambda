# circleci_docker_lambda

Builds and publishes the shared Docker image used by Fender/Presonus Lambda CI pipelines:

`opsfender/circleci:lambda_<branch>`

Consumers typically use `opsfender/circleci:lambda_main`.

## What’s in the image

| Tooling | Versions / notes |
|---|---|
| Base | `buildpack-deps:focal-scm` (Ubuntu Focal) plus common build libraries (see `BUILD_LIBS` in `scripts/generate.sh`); the Pythons are compiled in a separate `buildpack-deps:focal` stage and copied in, so the full set of -dev libraries isn't in the image |
| Node (nvm) | `20.12.1` (default), `24.14.1` + yarn + serverless@3.39.0 |
| Python (pyenv) | `3.6.8` (default), `3.7.2`, `3.8.5`, `3.12.10`, `3.14.3` |
| Go | `1.26.1` (+ cover, goveralls, honeymarker) |
| Terraform | tfenv with Terraform `1.17.2` (pinned by `TF_VERSION_REGEX`; keep in sync with `fenderdigital/circleci` `terraform/install_latest.sh`), tflint, tfsec, terraform-compliance |
| Terraform apply gate | AI reviewer venv at `/opt/tf-plan-review/venv` (Python `3.12.x`, from `scripts/tf_plan_review/requirements.lock`, a copy of `fenderdigital/circleci` `terraform/plan_gate/reviewer/requirements.lock`; keep them in sync) |
| Other | awscli, ansible, boto/boto3, zip/rsync/parallel/jq, etc. |

Versions are configured in `.circleci/config.yml` under `image_config`.

## How it works

1. Edit `image_config` in `.circleci/config.yml` (Node/Python/Go/tf versions, etc.).
2. Push to GitHub; CircleCI runs the `build` job.
3. `scripts/generate.sh` emits a `Dockerfile` from those env vars.
4. The image is built with `docker buildx` and pushed to Docker Hub as `$DOCKERHUB_USERNAME/circleci:lambda_$CIRCLE_BRANCH`, with zstd-compressed layers (smaller and faster to unpack than gzip; needs Docker 23+ to pull).
4a. The `smoke-test` job then runs on the pushed image, as app builds do, and checks its tools. Its "Spin up environment" step shows how long the pull took.
5. The generated `Dockerfile` is stored as a build artifact.

Docker Hub credentials come from the CircleCI **Global** context (`DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD`).

## Local notes

- `scripts/setup.sh` / `make setup` are leftover interactive wizard helpers; prefer editing `.circleci/config.yml` directly.
- Image builds run on CircleCI (`machine` executor); you do not need Docker Hub push access locally to change versions.
