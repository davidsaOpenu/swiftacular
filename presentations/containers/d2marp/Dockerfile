# We use debian instead of ubuntu because ubuntu does not directly package a browser.
# But we need a browser for marp to generate pdf files. Digest from debian:trixie-slim on 2026-08-01
FROM debian@sha256:020c0d20b9880058cbe785a9db107156c3c75c2ac944a6aa7ab59f2add76a7bd

ARG MARP_VERSION="4.5.0"
ARG D2_VERSION="v0.7.1"
ARG BUILD_UID=4099

ENV BUILD_UID="$BUILD_UID"

RUN export DEBIAN_FRONTEND=noninteractive \
	&& apt-get update \
	&& apt-get -y install firefox-esr npm golang \
	&& apt-get clean

RUN npm install -g "@marp-team/marp-cli@$MARP_VERSION" \
	&& npm cache clean --force

RUN export GOBIN=/usr/bin \
	&& go install "oss.terrastruct.com/d2@$D2_VERSION" \
	&& go clean -cache -modcache

RUN useradd -u "$BUILD_UID" -m -s /bin/bash user
USER user

COPY --chown='user:user' entrypoint.sh /usr/bin/entrypoint
ENTRYPOINT ["/usr/bin/entrypoint"]
WORKDIR /src
