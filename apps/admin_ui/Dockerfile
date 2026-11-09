FROM elixir:1.20-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --default-toolchain stable --profile minimal
ENV PATH="/root/.cargo/bin:${PATH}"

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
COPY lib lib
COPY priv priv
COPY assets assets

RUN mix compile
RUN mix assets.setup && mix assets.deploy
RUN mix release

FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libsctp1 openssl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/_build/prod/rel/admin_ui ./

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PORT=4000
EXPOSE 4000

CMD ["/app/bin/admin_ui", "start"]
