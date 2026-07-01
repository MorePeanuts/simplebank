DB_URL=postgresql://root:secret@localhost:5432/simple_bank?sslmode=disable

postgres:
	docker run --name pg18 --network bank-network -p 5432:5432 -e POSTGRES_USER=root -e POSTGRES_PASSWORD=secret -d postgres:18-alpine

createdb:
	docker exec -it pg18 createdb --username=root --owner=root simple_bank

dropdb:
	docker exec -it pg18 dropdb simple_bank

migrateup:
	migrate -path db/migration -database "$(DB_URL)" -verbose up

migrateup1:
	migrate -path db/migration -database "$(DB_URL)" -verbose up 1

migratedown:
	migrate -path db/migration -database "$(DB_URL)" -verbose down

migratedown1:
	migrate -path db/migration -database "$(DB_URL)" -verbose down 1

db_docs:
	dbdocs build doc/db.dbml

db_schema:
	dbml2sql --postgres -o doc/schema.sql doc/db.dbml

sqlc:
	sqlc generate

test:
	go test -v -cover ./...

server:
	go run main.go

mock:
	mockgen -package mockdb -destination db/mock/store.go github.com/MorePeanuts/simplebank/db/sqlc Store

proto:
	rm -f pb/*.proto
	protoc --proto_path=proto --go_out=pb --go_opt=paths=source_relative \
	--go-grpc_out=pb --go-grpc_opt=paths=source_relative \
	--grpc-gateway_out=pb --grpc-gateway_opt=paths=source_relative \
	proto/*.proto

evans:
	docker run --rm -it -v "$$(pwd):/mount:ro" -w /mount \
	ghcr.io/ktr0731/evans:latest \
	--path proto/ \
	--proto service_simple_bank.proto \
	--host host.docker.internal \
	--port 9090 \
	repl

.PHONY: postgres createdb dropdb migrateup migrateup1 migratedown migratedown1 db_docs db_schema sqlc test server mock proto evans
