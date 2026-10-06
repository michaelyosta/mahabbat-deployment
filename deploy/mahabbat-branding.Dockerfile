# Deployment-only overlay. Twenty source/core remains upstream and untouched.
FROM twentycrm/twenty:v2.29.0@sha256:9f9ea3df7ee81d940b40607419af560eee7b35f231c3a354f0a061472416c69e

COPY deploy/branding-overlay.mjs /deploy/branding-overlay.mjs
RUN node /deploy/branding-overlay.mjs
