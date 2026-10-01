# 职责：为真实集成验收提供独立P-256握手客户端，与Runtime业务无关。
# 边界：Test；cryptography 46.0.5，输入transport收发函数，输出经验证的ready。
# 生命周期：每次调用生成独立临时密钥；不保存登录状态，不打印secret。
# 不负责：不作为Unity/H5 SDK，不把Python结果替代客户端发布验证。
import hashlib
import hmac
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.hazmat.primitives.kdf.hkdf import HKDF


# 创建HELLO；返回私钥和公开消息，私钥只在当前测试进程拥有。
def hello():
    private = ec.generate_private_key(ec.SECP256R1())
    public = private.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint)
    return private, b'\x01\x01' + public


# 校验challenge并派生证明；返回proof和expected_ready供测试验证，不输出日志。
def respond(private, client_hello, challenge):
    assert len(challenge) == 99 and challenge[:3] == b'\x02\x01\x04'
    peer = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), challenge[2:67])
    z = private.exchange(ec.ECDH(), peer)
    transcript = hashlib.sha256(client_hello + challenge).digest()
    key = HKDF(algorithm=hashes.SHA256(), length=32, salt=challenge[67:],
               info=b'flywow/handshake/v1' + transcript).derive(z)
    proof = b'\x03' + hmac.digest(key, b'client-proof' + transcript, 'sha256')
    ready = b'\x04' + hmac.digest(key, b'server-ready' + transcript, 'sha256')
    return proof, ready


# 自动完成握手；send/receive为测试transport显式注入，失败立即传播给调用方关闭。
def perform(send, receive):
    private, message = hello()
    send(message)
    proof, expected = respond(private, message, receive())
    send(proof)
    assert hmac.compare_digest(receive(), expected), 'server proof mismatch'
