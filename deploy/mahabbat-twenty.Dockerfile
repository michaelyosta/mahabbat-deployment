# Mahabbat Twenty server image: upstream + fork patch + branding overlay.
#
# The Mahabbat fork (`mahabbat-twenty/`, upstream `twenty/v2.29.0` +
# `workspace:bootstrap:venue` CLI) is a source patch, not a full rebuild:
# Stage 1 starts from the official `twentycrm/twenty:v2.29.0` image and
# overlays the compiled fork command. Stage 2 applies the existing
# fail-closed branding overlay.
#
# Build from the deployment repository root with the fork present as
# `mahabbat-twenty/` (pinned commit in `mahabbat-twenty.lock.json`):
#
#   docker build -f deploy/mahabbat-twenty.Dockerfile -t mahabbat-twenty:v2.29.0-venue .
#
# Single-venue scope: the fork checkout is copied, not vendored in git
# (see .dockerignore exception below).
# ---- Single stage: upstream image + compiled fork patch + branding
# The fork command is pre-compiled to dist-style JS
# (`deploy/mahabbat-fork-patch/*.js`) because the upstream image ships no
# TS toolchain. The RUN step copies it into dist/ and registers it in
# `database-command.module.js` + `generate-api-key.command.js` by text
# patch (fail-closed: every anchor asserted).
FROM twentycrm/twenty:v2.29.0@sha256:9f9ea3df7ee81d940b40607419af560eee7b35f231c3a354f0a061472416c69e
COPY deploy/mahabbat-fork-patch/workspace-bootstrap-venue.command.js /tmp/mahabbat-fork-patch/
COPY deploy/mahabbat-fork-patch/workspace-rotate-api-key.command.js /tmp/mahabbat-fork-patch/
COPY deploy/mahabbat-fork-patch/inject-fork-patch.mjs /tmp/mahabbat-fork-patch/
RUN node /tmp/mahabbat-fork-patch/inject-fork-patch.mjs
COPY deploy/branding-overlay.mjs /deploy/branding-overlay.mjs
RUN node /deploy/branding-overlay.mjs
