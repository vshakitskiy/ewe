-- POST /echo with a fixed Content-Length body, exercising the buffered
-- (whole-body) request read path.

wrk.method = "POST"
wrk.body = string.rep("a", 4096)
wrk.headers["Content-Type"] = "application/octet-stream"
