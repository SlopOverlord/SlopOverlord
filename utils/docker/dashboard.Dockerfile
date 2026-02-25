FROM node:20-alpine
WORKDIR /dashboard
COPY Dashboard/package.json Dashboard/package-lock.json* ./
RUN npm install
COPY Dashboard .
EXPOSE 251019
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "251019"]
