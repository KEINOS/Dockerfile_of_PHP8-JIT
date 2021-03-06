#!/bin/bash -eu

cat <<'HEREDOC'
===============================================================================
  Local image builder for multiple architectures.
  Supporting architectures:
    ARM v6,v7 (RaspberryPi) and x86_64 (macOS, Windows Intel/AMD machines)
===============================================================================
This script will:

1. Build Docker images for ARM v6, ARM v7 and x86_64 (Intel/AMD64 compatible)
   architectures.
2. Pushes to Docker Hub the images made above.
3. Creates a "latest" manifest file which includes the above images and pushes
   to Docker Hub as well.

Requirements:

1. Experimental option of Docker must be enabled.("buildx" command must be
   available to use as well)
2. When running "docker buildx ls", the below platforms must be listed:
    - linux/arm/v6
    - linux/arm/v7
    - linux/arm64
    - linux/amd64

===============================================================================

HEREDOC

[ 'true' = "$(docker version --format '{{.Client.Experimental}}')" ] || {
    echo 'Docker daemon not in experimental mode.'
    exit 1
}

# -----------------------------------------------------------------------------
#  Functions
# -----------------------------------------------------------------------------

build_push_pull_image() {
    echo "- Remove image"
    docker image rm -f "${NAME_IMAGE_BASE}:${NAME_IMAGE_TAG}"
    echo "- Building image: ${NAME_PLATFORM}"
    docker buildx build \
        --build-arg NAME_IMAGE_BASE="$NAME_IMAGE_BASE" \
        --build-arg NAME_IMAGE_TAG="$NAME_IMAGE_TAG" \
        --build-arg ID_BUILD="$ID_BUILD_CURRENT" \
        --build-arg VERSION_PHP="$VERSION_PHP" \
        --build-arg VERSION_OS="$VERSION_OS" \
        --build-arg TAG_RELESED="$TAG_RELESED" \
        --platform "$NAME_PLATFORM" \
        -t "${NAME_IMAGE}:${NAME_IMAGE_TAG}" \
        --push . &&
        echo "  Pulling back image: ${NAME_IMAGE}:${NAME_IMAGE_TAG}" &&
        docker pull "${NAME_IMAGE}:${NAME_IMAGE_TAG}"

    return $?
}

create_builder() {
    echo "- Create builder: ${1}"
    if ! docker buildx ls | grep "$1" 1>/dev/null; then
        docker buildx create --name "$1"
    fi

    return $?
}

create_manifest() {
    echo '- Removing image from local:'
    docker image rm --force "$1" 2>/dev/null 1>/dev/null
    echo "- Creating manifest for: $1"
    echo "  With images: ${2}"
    docker manifest create "$1" "$2" --amend

    return $?
}

get_core_number() {
    if which nproc 2>/dev/null 1>/dev/null; then
        nproc
    else
        sysctl -n hw.logicalcpu_max
    fi
}

get_version_alpine_latest() {
    docker run --rm -i keinos/alpine cat /etc/os-release | grep VERSION_ID | sed -e 's/[^0-9\.]//g'
}

indent_stdin() {
    indent='    '
    while read -r line; do
        echo "${indent}${line}"
    done
    echo
}

login_docker() {
    echo -n '- Login to Docker: '
    docker login 2>/dev/null 1>/dev/null || {
        echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin || {
            echo 'You need to login Docker Cloud/Hub first.'
            exit 1
        }
    }
    echo 'OK'
}

rewrite_variant_manifest() {
    echo "- Re-writing ${1} variant from: ${2} to: ${3}"
    docker manifest annotate "$1" "$2" --variant "$3"

    return $?
}

# -----------------------------------------------------------------------------
#  Common Variables
# -----------------------------------------------------------------------------
VERSION_PHP='8.0.0-dev'
VERSION_OS=$(get_version_alpine_latest)
ID_BUILD_CURRENT=$(date '+%Y%m%d')

NAME_IMAGE='keinos/php8-jit'
NAME_BUILDER='mybuilder'
NAME_FILE_VER_INFO='info-build.txt'

NUM_CORE=$(get_core_number)
PATH_DIR_SELF=$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)
PATH_FILE_VER_INFO="${PATH_DIR_SELF}/${NAME_FILE_VER_INFO}"

export NUM_CORE
export PATH_DIR_SELF
export PATH_FILE_VER_INFO

TAG_RELESED="${VERSION_PHP}-build-${ID_BUILD_CURRENT}"

# -----------------------------------------------------------------------------
#  Main
# -----------------------------------------------------------------------------

# Setup docker for multi-arc
login_docker

create_builder $NAME_BUILDER || {
    echo 'Failed to build builder'
}

echo '- Start build:'
docker buildx use $NAME_BUILDER
docker buildx inspect --bootstrap

# =============
#  BUILD IMAGE
# =============
# For debug reasons do not loop the below build steps
# Build ARMv6
NAME_IMAGE_BASE='keinos/alpine'
NAME_IMAGE_TAG='armv6'
NAME_PLATFORM='linux/arm/v6'
build_push_pull_image

# Build ARMv7
NAME_IMAGE_BASE='keinos/alpine'
NAME_IMAGE_TAG='armv7'
NAME_PLATFORM='linux/arm/v7'
build_push_pull_image

# Build ARM64
NAME_IMAGE_BASE='keinos/alpine'
NAME_IMAGE_TAG='arm64'
NAME_PLATFORM='linux/arm64'
build_push_pull_image

# Build AMD64
NAME_IMAGE_BASE='keinos/alpine'
NAME_IMAGE_TAG='amd64'
NAME_PLATFORM='linux/amd64'
build_push_pull_image

# ======================
#  INSPECT BUILT IMAGES
# ======================
echo "- Inspect built image of: ${NAME_IMAGE}"
docker buildx imagetools inspect $NAME_IMAGE

echo '- Switch back builder to default:'
docker buildx stop $NAME_BUILDER
docker buildx use default

# =================
#  CREATE MANIFEST
# =================

LIST_IMAGE_INCLUDE="${NAME_IMAGE}:armv6 ${NAME_IMAGE}:armv7 ${NAME_IMAGE}:arm64 ${NAME_IMAGE}:amd64"

echo -n '- Prune all the files to ensure not to add duplicate ... '
docker system prune -f -a >/dev/null && {
    echo 'OK'
}

echo "- Pulling back all the built images of ${NAME_IMAGE} ..."
for each in $LIST_IMAGE_INCLUDE; do
    docker pull "$each" |
        while read -r line; do
            printf "\r%${lenLine:-${#line}}s\r"
            printf '%s' "$line"
            lenLine=${#line}
        done
    echo
done

# -----------------------------------------------------------------------------
#  Create manifest list with latest version
# -----------------------------------------------------------------------------
NAME_IMAGE_AND_TAG="${NAME_IMAGE}:latest"
echo "- Creating manifest for image: ${NAME_IMAGE} tag:${NAME_IMAGE_AND_TAG}"

create_manifest "$NAME_IMAGE_AND_TAG" "$LIST_IMAGE_INCLUDE"

# Re-write the variant for ARM6 and ARM7 architecture for RPIs
rewrite_variant_manifest "$NAME_IMAGE_AND_TAG $NAME_IMAGE":armv6 v6l
rewrite_variant_manifest "$NAME_IMAGE_AND_TAG $NAME_IMAGE":armv7 v7l

docker manifest inspect "$NAME_IMAGE_AND_TAG" &&
    docker manifest push "$NAME_IMAGE_AND_TAG" --purge &&
    docker image rm -f "$NAME_IMAGE_AND_TAG"

# -----------------------------------------------------------------------------
#  Create manifest list with current version
# -----------------------------------------------------------------------------
NAME_IMAGE_AND_TAG="${NAME_IMAGE}:build_${ID_BUILD_CURRENT}"
echo "- Creating manifest for image: ${NAME_IMAGE} tag:${NAME_IMAGE_AND_TAG}"

create_manifest "$NAME_IMAGE_AND_TAG" "$LIST_IMAGE_INCLUDE"

# Re-write the variant for ARM6 and ARM7 architecture for RPIs
rewrite_variant_manifest "$NAME_IMAGE_AND_TAG $NAME_IMAGE":armv6 v6l
rewrite_variant_manifest "$NAME_IMAGE_AND_TAG $NAME_IMAGE":armv7 v7l

# ===============
#  PUSH MANIFEST
# ===============
docker manifest inspect "$NAME_IMAGE_AND_TAG" &&
    docker manifest push "$NAME_IMAGE_AND_TAG" --purge &&
    docker image rm -f "$NAME_IMAGE_AND_TAG"
