FROM joseluisq/static-web-server:2-alpine

COPY public/ /public/
COPY sws.toml /sws.toml
COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
