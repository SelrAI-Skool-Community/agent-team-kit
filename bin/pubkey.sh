#!/usr/bin/env bash
# Print the public key for the identity in .env, so you can add it as a member
# in the Buzz app. Your private key is never printed or sent anywhere.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
[ -f "$ROOT/.env" ] && . "$ROOT/.env"
KEY="${BUZZ_PRIVATE_KEY:-}"
[ -n "$KEY" ] || { echo "BUZZ_PRIVATE_KEY is empty in .env. Make one with: openssl rand -hex 32"; exit 1; }
python3 - "$KEY" <<'PY'
import sys
CH="qpzry9x8gf2tvdw0s3jn54khce6mua7l"
P=2**256-2**32-977
N=0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
Gx=0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
Gy=0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8
def inv(a,m=P): return pow(a,m-2,m)
def add(p,q):
    if p is None: return q
    if q is None: return p
    if p[0]==q[0] and (p[1]+q[1])%P==0: return None
    l=((3*p[0]*p[0])*inv(2*p[1]))%P if p==q else ((q[1]-p[1])*inv(q[0]-p[0]))%P
    x=(l*l-p[0]-q[0])%P
    return (x,(l*(p[0]-x)-p[1])%P)
def mul(k,p=(Gx,Gy)):
    r=None
    while k:
        if k&1: r=add(r,p)
        p=add(p,p); k>>=1
    return r
def polymod(v):
    G=[0x3b6a57b2,0x26508e6d,0x1ea119fa,0x3d4233dd,0x2a1462b3]; c=1
    for x in v:
        b=c>>25; c=((c&0x1ffffff)<<5)^x
        for i in range(5):
            if (b>>i)&1: c^=G[i]
    return c
def hx(h): return [ord(c)>>5 for c in h]+[0]+[ord(c)&31 for c in h]
def cb(data,f,t,pad=True):
    acc=bits=0; out=[]; mx=(1<<t)-1
    for b in data:
        acc=(acc<<f)|b; bits+=f
        while bits>=t: bits-=t; out.append((acc>>bits)&mx)
    if pad and bits: out.append((acc<<(t-bits))&mx)
    return out
def enc(hrp,d):
    c=d+[(polymod(hx(hrp)+d+[0]*6)^1)>>5*(5-i)&31 for i in range(6)]
    return hrp+"1"+"".join(CH[x] for x in c)
try:
    sk=int(sys.argv[1].strip(),16)%N
except ValueError:
    sys.exit("That does not look like a hex key. Make one with: openssl rand -hex 32")
pub=format(mul(sk)[0],"064x")
print("Add this as a member in the Buzz app:\n")
print("  " + enc("npub", cb(bytes.fromhex(pub),8,5)))
print("\n(hex form, if the app asks for that instead: " + pub + ")")
PY
