FROM joseluisq/static-web-server:2

COPY public/ /public/
COPY config.toml /config.toml
