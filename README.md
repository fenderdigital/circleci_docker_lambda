# circleci_docker_lambda

Builds and publishes the shared Docker image used by Fender/Presonus Lambda CI pipelines:

`opsfender/circleci:lambda_<branch>`

Consumers typically use `opsfender/circleci:lambda_main`.

## What’s in the image

| Tooling | Versions / notes |
|---|---|
| Base | `buildpack-deps` (Ubuntu Focal) |
| Node (nvm) | `20.12.1` (default), `24.14.1` + yarn + serverless@3.39.0 |
| Python (pyenv) | `3.6.8` (default), `3.7.2`, `3.8.5`, `3.12.10`, `3.14.3` |
| Go | `1.26.1` (+ cover, goveralls, honeymarker) |
| Terraform | tfenv (`latest` stable), tflint, tfsec, terraform-compliance |
| Other | awscli, ansible, boto/boto3, zip/rsync/parallel/jq, etc. |

Versions are configured in `.circleci/config.yml` under `image_config`.

## How it works

1. Edit `image_config` in `.circleci/config.yml` (Node/Python/Go/tf versions, etc.).
2. Push to GitHub; CircleCI runs the `build` job.
3. `scripts/generate.sh` emits a `Dockerfile` from those env vars.
4. The image is built and pushed to Docker Hub as `$DOCKERHUB_USERNAME/circleci:lambda_$CIRCLE_BRANCH`.
5. The generated `Dockerfile` is stored as a build artifact.

Docker Hub credentials come from the CircleCI **Global** context (`DOCKERHUB_USERNAME`, `DOCKERHUB_PASSWORD`).

## Local notes

- `scripts/setup.sh` / `make setup` are leftover interactive wizard helpers; prefer editing `.circleci/config.yml` directly.
- Image builds run on CircleCI (`machine` executor); you do not need Docker Hub push access locally to change versions.
