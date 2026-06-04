# Build a static arm64 vsock-relay and package it as a scratch image suitable
# for use as a LinuxKit service.
ARG GO_BUILD_IMAGE=golang:1.23-alpine
FROM ${GO_BUILD_IMAGE} AS build
WORKDIR /src
COPY go.mod ./
COPY main.go ./
RUN go mod tidy
RUN CGO_ENABLED=0 GOOS=linux GOARCH=arm64 go build -trimpath -o /vsock-relay .

FROM scratch
COPY --from=build /vsock-relay /vsock-relay
ENTRYPOINT ["/vsock-relay"]
