wrk.method = "POST"
wrk.body = string.rep("a", 1024)
wrk.headers["Content-Type"] = "application/octet-stream"
