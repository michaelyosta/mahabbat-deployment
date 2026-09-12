# Deployment-only overlay. Twenty source/core remains upstream and untouched.
FROM twentycrm/twenty:v2.29.0

COPY deploy/branding-overlay.mjs /deploy/branding-overlay.mjs
RUN node /deploy/branding-overlay.mjs
