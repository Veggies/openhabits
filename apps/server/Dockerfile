# Build from the repo root: docker build -f apps/server/Dockerfile .
FROM dart:3.14 AS build

WORKDIR /app
# The full workspace includes the Flutter client, which needs the Flutter SDK
# to resolve, so the image builds with a workspace of just core + server.
RUN printf 'name: workspace\npublish_to: none\nenvironment:\n  sdk: ^3.14.0\nworkspace:\n  - packages/core\n  - apps/server\n' > pubspec.yaml
COPY packages/core/pubspec.yaml packages/core/
COPY apps/server/pubspec.yaml apps/server/
RUN dart pub get

COPY packages/core packages/core
COPY apps/server apps/server
WORKDIR /app/apps/server
RUN dart pub get --offline && dart build cli --target bin/server.dart -o output

# Minimal serving image: the AOT-compiled server, its bundled native
# libraries (SQLite) and the AOT runtime from the base image.
FROM scratch
COPY --from=build /runtime/ /
COPY --from=build /app/apps/server/output/bundle/ /app/

ENV DB_PATH=/data/data.sqlite
VOLUME /data
# 8080: home network and setup page. 8443: HTTPS for remote access.
EXPOSE 8080 8443
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
  CMD ["/app/bin/server", "--healthcheck"]
CMD ["/app/bin/server"]
