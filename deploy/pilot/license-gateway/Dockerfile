FROM node:24-alpine
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts && npm cache clean --force
COPY src ./src
ENV NODE_ENV=production
EXPOSE 3000 3100 3199
CMD ["node", "src/server.mjs"]
