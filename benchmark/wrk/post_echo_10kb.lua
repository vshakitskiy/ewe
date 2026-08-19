wrk.method = "POST"
wrk.body = string.rep("a", 10240)
wrk.headers["Content-Type"] = "application/octet-stream"
