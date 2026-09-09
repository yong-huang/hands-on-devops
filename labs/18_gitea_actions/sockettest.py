import socket, json, tarfile, io
def req(method, path, body=None, ctype="application/json"):
    payload = body if isinstance(body, bytes) else (json.dumps(body).encode() if body else b"")
    hdr = f"{method} {path} HTTP/1.1\r\nHost: d\r\nContent-Type: {ctype}\r\nContent-Length: {len(payload)}\r\nConnection: close\r\n\r\n"
    s2 = socket.socket(socket.AF_UNIX); s2.settimeout(15); s2.connect("/var/run/docker.sock")
    s2.send(hdr.encode()+payload)
    resp = b""
    while True:
        chunk = s2.recv(65536)
        if not chunk: break
        resp += chunk
    s2.close()
    return resp
r = req("POST", "/v1.44/containers/create?name=copitest-x", {"Image":"python:3.12-slim","Cmd":["sleep","30"]})
body = r.split(b"\r\n\r\n",1)[1]
print(r.decode(errors="replace").split("\r\n")[0])
cid = json.loads(body[body.index(b"{"):])["Id"]
print(req("POST", f"/v1.44/containers/{cid}/start").decode().split("\r\n")[0])
buf = io.BytesIO(); tf = tarfile.open(fileobj=buf, mode="w")
ti = tarfile.TarInfo("t.bin"); ti.size = 4096
tf.addfile(ti, io.BytesIO(b"y"*4096)); tf.close()
print(req("PUT", f"/v1.44/containers/{cid}/archive?path=/tmp", buf.getvalue(), "application/x-tar").decode().split("\r\n")[0])
req("DELETE", f"/v1.44/containers/{cid}?force=1")
