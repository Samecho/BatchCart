FROM node:24-bookworm-slim AS frontend
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json vite.config.ts ./
COPY frontend frontend
RUN npm run build

FROM ruby:3.4-slim AS gems
RUN apt-get update && apt-get install -y --no-install-recommends build-essential libpq-dev \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /app
COPY Gemfile* ./
RUN bundle install

FROM ruby:3.4-slim
RUN apt-get update && apt-get install -y --no-install-recommends libpq5 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 1000 rails
WORKDIR /app
COPY --from=gems /usr/local/bundle /usr/local/bundle
COPY --chown=rails:rails . .
COPY --chown=rails:rails --from=frontend /app/public/assets public/assets
RUN mkdir -p log tmp/pids && chown -R rails:rails log tmp
USER rails
EXPOSE 3000
CMD ["bundle", "exec", "rails", "server", "-b", "0.0.0.0"]
