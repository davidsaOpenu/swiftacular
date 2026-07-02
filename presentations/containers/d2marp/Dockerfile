# We use debian instead of ubuntu becuase ubuntu does not directly package a browser.
# But we need a browser for marp to generate pdf files.
FROM debian:trixie-slim

ARG MARP_VERSION="4.5.0"
ARG D2_VERSION="v0.7.1"
ARG BUILD_UID=4099

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

COPY entrypoint.sh /usr/bin/entrypoint
ENTRYPOINT ["/usr/bin/entrypoint"]
WORKDIR /src
