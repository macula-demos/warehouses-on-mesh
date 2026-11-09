FROM elixir:1.20-slim AS build

RUN apt-get update \
    && apt-get install -y --no-install-recommends build-essential git ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
ENV MIX_ENV=prod

RUN mix local.hex --force && mix local.rebar --force

COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

COPY config config
COPY lib lib

RUN mix compile && mix release

FROM debian:trixie-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates curl libsctp1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY --from=build /app/_build/prod/rel/freezer_controller ./

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8
ENV PORT=8080
EXPOSE 8080

CMD ["/app/bin/freezer_controller", "start"]
