FROM ghcr.io/jina-ai/reader@sha256:8cc9a5cf6dc9c240235fccc0026661de74b6e13c21b36e6a86b3281b9ef10f28

# The upstream OSS image is the source of the application. This tiny derived
# layer closes the two open self-hosted SSRF paths documented in jina-ai/reader
# issues #1252 and #1253 without granting Chrome SYS_ADMIN.
USER root
COPY harden-reader.js /tmp/harden-reader.js
RUN node /tmp/harden-reader.js && rm -f /tmp/harden-reader.js
USER jina
