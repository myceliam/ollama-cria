# searxng-mcp for the VPS web egress (docs/RESTORE.md Stage 5b, R-13).
# The live VPS runs this one server from the PC's whole mcpo image; this
# builds only what it needs: mcp-searxng 1.6.0 (the version in
# stack/Dockerfile.mcpo) on Node 22, pinned by digest (7 October 2026).
FROM node:22-alpine@sha256:0a7108bf6c7bf5de370ffb1a3ed6be93d405b43ff159f681a8d18c0e2bc2e402
RUN npm install -g --omit=dev mcp-searxng@1.6.0 \
 && npm cache clean --force
USER node
ENTRYPOINT ["node", "/usr/local/lib/node_modules/mcp-searxng/dist/cli.js"]
