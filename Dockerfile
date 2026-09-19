ARG VERSION=dev
FROM golang:1.27.1-alpine3.24 AS builder
ARG VERSION
WORKDIR /build
COPY server/go.mod ./
RUN go mod download || true
COPY server/main.go .
RUN GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux \
    go build -ldflags="-w -s -X main.version=${VERSION}" -o spade .

FROM scratch
COPY --from=builder /build/spade /spade
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY public/ /public/
EXPOSE 80
ENTRYPOINT ["/spade"]
