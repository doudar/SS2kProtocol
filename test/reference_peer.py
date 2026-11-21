"""Independent OpenSSL-backed server for protocol interoperability tests.

These constants are public test fixtures. This peer performs no network I/O.
"""
import hashlib
import hmac
import json
import struct
import sys
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers.aead import AESCCM
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


def derive(secret, salt, label, length):
    return HKDF(algorithm=hashes.SHA256(), length=length, salt=salt,
                info=label).derive(secret)


def proof(root, label, transcript=b''):
    return hmac.digest(root, label + transcript, 'sha256')[:16]


def pair(hello, device_id):
    private = ec.derive_private_key(137, ec.SECP256R1())
    peer = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), hello[9:])
    offer = b'\xa3' + private.public_key().public_bytes(
        serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    root = derive(private.exchange(ec.ECDH(), peer), hashlib.sha256(
        hello + offer + device_id).digest(), b'SS2K/pair/v1', 32)
    return dict(offer=offer, root=root, client=b'\xa4'+proof(root,b'client'),
                paired=b'\xa5'+proof(root,b'device'))


def session(hello, device_id, root):
    server_random = bytes(range(16))
    transcript = hashlib.sha256(device_id + hello + server_random).digest()
    material = derive(root, transcript, b'SS2K/session/v1', 64)
    def record(key, prefix, payload, sequence=0):
        header = b'\xd0' + struct.pack('<I', sequence)
        return header + AESCCM(key,tag_length=8).encrypt(prefix+header[1:], payload, header)
    return dict(challenge=b'\xb1'+server_random+proof(root,b'server',transcript),
                prove=b'\xb2'+proof(root,b'client',transcript),
                ready=b'\xb3'+proof(root,b'ready',transcript),
                request=record(material[:16], material[32:40], b'\x01\x25'),
                response=record(material[16:32], material[40:48], b'\x80\x25test'),
                dircon_chunk=record(material[:16], material[32:40],
                                    b'\x02\x38\x01' + struct.pack('<I', 1024) + bytes(range(256)) * 8, 1))


if __name__ == '__main__':
    # Read public test data on stdin. Root bytes never appear in command arguments.
    data = {k:bytes.fromhex(v) for k,v in json.load(sys.stdin).items()}
    result = session(**data) if 'root' in data else pair(**data)
    print(json.dumps({k:v.hex() for k,v in result.items()}))
