########################################
# Stage 1: Build Elixir release
########################################
FROM elixir:1.19.5-otp-28 AS builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      build-essential git curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

ENV MIX_ENV=prod
ENV XLA_TARGET=cpu
ENV EXLA_TARGET=host

WORKDIR /app

# Install hex + rebar
RUN mix local.hex --force && mix local.rebar --force

# Copy dependency files first for caching
COPY mix.exs mix.lock ./
RUN mix deps.get --only prod

# Compile deps first (heavy: EXLA C++) so editing lib/ doesn't bust this layer
COPY config config
RUN mix deps.compile

# Copy source code and compile only app
COPY lib lib
COPY priv priv
RUN mix compile

# Build release
RUN mix release

########################################
# Stage 2: Runtime image
#
# NOTE: We tried alpine:3.21 + gcompat to mirror upstream alpine impls, but
# hexpm/elixir does not publish 1.19.5 + OTP 28 alpine builds, so the BEAM is
# linked against glibc 2.38+ and references __isoc23_* symbols that gcompat
# does not provide. Using debian:trixie-slim keeps the ABI consistent with
# the builder while staying small (~80MB).
########################################
FROM debian:trixie-slim AS runtime

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      libstdc++6 \
      libgcc-s1 \
      libtinfo6 \
      libssl3 \
      ca-certificates \
      locales && \
    rm -rf /var/lib/apt/lists/* && \
    sed -i 's/^# *\(C.UTF-8\)/\1/' /etc/locale.gen 2>/dev/null || true

ENV LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    MIX_ENV=prod \
    XLA_TARGET=cpu \
    EXLA_TARGET=host \
    ERL_CRASH_DUMP_SECONDS=0

WORKDIR /app

COPY --from=builder /app/_build/prod/rel/rinha ./

# References + IVF index are bind-mounted at /app/{references_v2,ivf_index}.bin
# by docker-compose so the same files are shared between api1 and api2 with a
# single on-disk copy. If you run this image standalone, pass:
#   -v ./priv/references_v2.bin:/app/references_v2.bin:ro
#   -v ./priv/ivf_index.bin:/app/ivf_index.bin:ro

COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

ENV PORT=4000 \
    REFERENCES_V2_PATH=/app/references_v2.bin \
    IVF_INDEX_PATH=/app/ivf_index.bin \
    READY_FILE=/tmp/ready \
    RELEASE_DISTRIBUTION=sname

EXPOSE 4000

CMD ["/app/entrypoint.sh"]
