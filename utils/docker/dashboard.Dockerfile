FROM node:20-alpine
WORKDIR /dashboard
COPY Dashboard/package.json Dashboard/package-lock.json* ./
RUN npm install
COPY Dashboard .
EXPOSE 25102
CMD ["npm", "run", "dev", "--", "--host", "0.0.0.0", "--port", "25102"]
