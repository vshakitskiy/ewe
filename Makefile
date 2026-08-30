autobahn_test:
	gleam run -m autobahn & sleep 2

	docker run -it --rm \
  -v "${PWD}/autobahn/config.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json

	kill $$(lsof -t -i:8080)

autobahn_h2_test:
	gleam run -m autobahn & sleep 2

	nghttpx -f'127.0.0.1,9000;no-tls' -b'127.0.0.1,8080;;proto=h2;no-tls' & sleep 1

	docker run -it --rm \
  -v "${PWD}/autobahn/config.h2.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json

	kill $$(lsof -t -i:9000) $$(lsof -t -i:8080)

autobahn_docker:
	docker run -it --rm \
  -v "${PWD}/autobahn/config.json:/autobahn.json" \
  -v "${PWD}/autobahn:/reports" \
  --network host \
  crossbario/autobahn-testsuite \
  wstest -m fuzzingclient -s /autobahn.json

autobahn_serve:
	cd "${PWD}/autobahn" && bun run serve.ts
