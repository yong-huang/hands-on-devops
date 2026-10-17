#!/usr/bin/env python3
"""
OIDC token 验签脚本——离线验证 GitHub 签发的 JWT。

用法：
  python3 verify_oidc.py <token-file>           # 验签 + 断言 claims
  python3 verify_oidc.py <token-file> --tamper  # 篡改 payload 后验签应失败

验签流程：
  1. 拆 JWT 三段（header.payload.signature）
  2. 从 https://token.actions.githubusercontent.com/.well/openid-config
     拿到 JWKS URI → 拉取公钥集合
  3. 按 header.kid 匹配公钥
  4. 用 cryptography 库验证 RS256 签名
  5. 解码 payload，断言 repository / ref
  6. 篡改 payload 的一个字符，验签应失败（反例）
"""
import base64, json, sys, urllib.request, os

JWKS_URL = "https://token.actions.githubusercontent.com/.well-known/jwks"
OIDC_CONFIG_URL = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"

def b64url_decode(data):
    """base64url → bytes（自动补 =）"""
    pad = 4 - len(data) % 4
    if pad != 4:
        data += "=" * pad
    return base64.urlsafe_b64decode(data)

def fetch_jwks():
    """从 OIDC config → JWKS URI 拉取公钥集合"""
    # 先从 openid-configuration 拿真正的 JWKS URI
    req = urllib.request.Request(OIDC_CONFIG_URL)
    with urllib.request.urlopen(req, timeout=15) as resp:
        config = json.loads(resp.read())
    jwks_uri = config.get("jwks_uri", JWKS_URL)
    req = urllib.request.Request(jwks_uri)
    with urllib.request.urlopen(req, timeout=15) as resp:
        return json.loads(resp.read())

def jwk_to_pem(jwk):
    """JWK → PEM（RS256 公钥）"""
    from cryptography.hazmat.primitives.asymmetric.rsa import RSAPublicNumbers
    from cryptography.hazmat.primitives import serialization
    n = int.from_bytes(b64url_decode(jwk["n"]), "big")
    e = int.from_bytes(b64url_decode(jwk["e"]), "big")
    pub = RSAPublicNumbers(e, n).public_key()
    return pub.public_bytes(
        serialization.Encoding.PEM,
        serialization.PublicFormat.SubjectPublicKeyInfo
    )

def verify_signature(token, jwks):
    """验证 RS256 签名"""
    from cryptography.hazmat.primitives.asymmetric import padding
    from cryptography.hazmat.primitives import hashes
    from cryptography.exceptions import InvalidSignature

    header_b64, payload_b64, sig_b64 = token.split(".")
    header = json.loads(b64url_decode(header_b64))
    kid = header.get("kid")
    alg = header.get("alg", "RS256")

    signing_input = f"{header_b64}.{payload_b64}".encode()
    signature = b64url_decode(sig_b64)

    for jwk in jwks.get("keys", []):
        if jwk.get("kid") == kid:
            pem = jwk_to_pem(jwk)
            from cryptography.hazmat.primitives.serialization import load_pem_public_key
            pub_key = load_pem_public_key(pem)
            if alg == "RS256":
                pub_key.verify(signature, signing_input, padding.PKCS1v15(), hashes.SHA256())
            return True
    raise ValueError(f"kid {kid} not found in JWKS")

def tamper(token):
    """篡改 payload 的最后一个字符（A→B 或首字符+1）"""
    header_b64, payload_b64, sig_b64 = token.split(".")
    payload_bytes = bytearray(b64url_decode(payload_b64))
    # 翻转最后一个字节的最低位
    payload_bytes[-1] ^= 0x01
    tampered = base64.urlsafe_b64encode(bytes(payload_bytes)).rstrip(b"=").decode()
    return f"{header_b64}.{tampered}.{sig_b64}"

def main():
    if len(sys.argv) < 2:
        print(__doc__)
        sys.exit(1)

    token_file = sys.argv[1]
    do_tamper = "--tamper" in sys.argv

    with open(token_file) as f:
        token = f.read().strip()

    if do_tamper:
        token = tamper(token)
        print("[tamper] payload 已篡改")

    # 拉取 JWKS
    print("[1] 拉取 JWKS …")
    jwks = fetch_jwks()
    print(f"    {len(jwks.get('keys', []))} 个公钥")

    # 验签
    print("[2] 验证 RS256 签名 …")
    try:
        verify_signature(token, jwks)
        print("    [ok] 签名验证通过")
    except Exception as e:
        print(f"    [fail] 签名验证失败: {e}")
        if do_tamper:
            print("[ok] 篡改后验签失败——反例取证通过")
            sys.exit(0)
        sys.exit(1)

    if do_tamper:
        print("[!] 篡改后验签竟通过——异常" )
        sys.exit(1)

    # 解码 claims
    print("[3] 解码 claims …")
    _, payload_b64, _ = token.split(".")
    claims = json.loads(b64url_decode(payload_b64))

    # 断言关键 claims
    repo = claims.get("repository", "")
    ref = claims.get("ref", "")
    actor = claims.get("actor", "")
    aud = claims.get("aud", "")

    print(f"    repository: {repo}")
    print(f"    ref:        {ref}")
    print(f"    actor:      {actor}")
    print(f"    aud:        {aud}")

    assert "cicd-lab" in repo, f"repository 不含 cicd-lab: {repo}"
    assert ref, "ref 为空"

    print("[ok] claims 断言通过：repository 与 ref 均匹配")

if __name__ == "__main__":
    main()
