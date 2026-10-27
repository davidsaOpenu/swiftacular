# We use debian instead of ubuntu because ubuntu does not directly package a browser.
# But we need a browser for marp to generate pdf files. Digest from debian:trixie-slim on 2026-08-01
ARG BASE_IMAGE="debian@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd"

# d2 is built in its own stage so the Go toolchain stays out of the final image.
FROM $BASE_IMAGE AS d2

ARG D2_VERSION="v0.7.1"

RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get -y install --no-install-recommends golang ca-certificates git \
	&& rm -rf /var/lib/apt/lists/*

RUN export GOBIN=/usr/local/bin \
	&& go install "oss.terrastruct.com/d2@$D2_VERSION"

FROM $BASE_IMAGE

ARG MARP_VERSION="4.5.0"

RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get -y install --no-install-recommends firefox-esr npm fonts-dejavu-core \
	&& apt-get clean \
	&& rm -rf /var/lib/apt/lists/*

RUN npm install -g "@marp-team/marp-cli@$MARP_VERSION" \
	&& npm cache clean --force

COPY --from=d2 /usr/local/bin/d2 /usr/bin/d2

# Last layers that depend on BUILD_UID, so changing it only invalidates the tail.
ARG BUILD_UID=4099
ENV BUILD_UID="$BUILD_UID"
RUN useradd -u "$BUILD_UID" -m -s /bin/bash user
USER user

COPY --chown='user:user' entrypoint.sh /usr/bin/entrypoint
ENTRYPOINT ["/usr/bin/entrypoint"]
WORKDIR /src
