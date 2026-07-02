# Build stage
FROM golang:1.25-alpine3.23 AS builder
WORKDIR /app
SHELL [ "/bin/ash", "-o", "pipefail", "-c" ]
COPY go.mod go.sum ./
RUN go mod download
COPY . .
RUN go build -o main main.go


# Run stage
FROM alpine:3.23
WORKDIR /app
COPY --from=builder /app/main .
COPY app.env .
COPY db/migration ./db/migration
COPY start.sh .

EXPOSE 8080
CMD [ "/app/main" ]
ENTRYPOINT [ "/app/start.sh" ]

