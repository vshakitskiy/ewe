wrk.method = "POST"

local encoded = ""
for _ = 1, 10 do
  local chunk = string.rep("a", 1024)
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
