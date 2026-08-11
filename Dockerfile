FROM joseluisq/static-web-server:2

COPY public/ /public/
COPY sws.toml /sws.toml
