FROM golang:1.23-alpine AS builder
WORKDIR /build
COPY server/go.mod ./
RUN go mod download || true
COPY server/main.go .
RUN GOFLAGS=-mod=mod CGO_ENABLED=0 GOOS=linux \
    go build -ldflags="-w -s" -o spade .

FROM scratch
COPY --from=builder /build/spade /spade
COPY --from=builder /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY public/ /public/
EXPOSE 80
ENTRYPOINT ["/spade"]
