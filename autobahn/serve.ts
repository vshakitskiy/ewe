// This was done, so it would be easier for me to access the autobahn results via the browser, as I am connecting and
// working on my homelab.
const server = Bun.serve({
  fetch: async (req) => {
    const file = Bun.file(`./server_h2${new URL(req.url).pathname}`);
    if (await file.exists()) return new Response(file);

    return new Response("Not Found", { status: 404 });
  },
  port: 3000,
  hostname: "192.168.1.41",
});

console.log(`Server running at ${server.url}`);
