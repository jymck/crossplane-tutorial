FROM golang:1.24-alpine AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY *.go ./
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/azure-sql-demo .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/azure-sql-demo /azure-sql-demo
EXPOSE 8080
ENTRYPOINT ["/azure-sql-demo"]
