-- POST /echo/chunked with a Transfer-Encoding: chunked body, exercising the
-- incremental/streamed request read path. wrk has no built-in support for
-- chunked request bodies, so the raw request is hand-built here.

wrk.method = "POST"

local chunks = {
  string.rep("a", 1024),
  string.rep("b", 1024),
  string.rep("c", 1024),
  string.rep("d", 1024),
}

local encoded = ""
for _, chunk in ipairs(chunks) do
  encoded = encoded .. string.format("%x", #chunk) .. "\r\n" .. chunk .. "\r\n"
end
encoded = encoded .. "0\r\n\r\n"

request = function()
  return "POST /echo/chunked HTTP/1.1\r\n" ..
         "Host: 127.0.0.1\r\n" ..
         "Transfer-Encoding: chunked\r\n" ..
         "Content-Type: application/octet-stream\r\n" ..
         "Connection: keep-alive\r\n\r\n" ..
         encoded
end
