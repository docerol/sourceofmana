extends RefCounted
class_name Hasher

#
const DefaultSaltSize : int				= 16
const DefaultTokenSize : int			= 32
const DefaultResetCodeLength : int		= 6

# Password
# SOM-IDLE A1: KDF stretching (iterated SHA-256) + CSPRNG salts.
# ver 0 = legacy single SHA-256(salt + password) — verify-only, upgraded on login.
# ver 1 = KDF_ITERATIONS x SHA-256(prev + salt). New accounts always ver 1.
const KdfIterations : int = 12000
const HashVersion : int = 1

static func GenerateSalt(length : int = DefaultSaltSize) -> String:
	var crypto : Crypto = Crypto.new()
	var bytes : PackedByteArray = crypto.generate_random_bytes(length)
	if bytes.size() == length:
		return bytes.hex_encode().substr(0, length * 2)
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var salt : String = ""
	for i in length:
		salt += char(rng.randi_range(33, 126))
	return salt

static func _sha256_hex(data : PackedByteArray) -> String:
	var hashContext : HashingContext = HashingContext.new()
	hashContext.start(HashingContext.HASH_SHA256)
	hashContext.update(data)
	return hashContext.finish().hex_encode()

static func HashPassword(password : String, salt : String = "") -> String:
	return _sha256_hex((salt + password).to_utf8_buffer())

static func HashPasswordV1(password : String, salt : String) -> String:
	var hex : String = _sha256_hex((salt + password).to_utf8_buffer())
	for i in range(1, KdfIterations):
		hex = _sha256_hex((hex + salt).to_utf8_buffer())
	return hex

static func VerifyPassword(password : String, salt : String, storedHash : String, hashVer : int = 0) -> bool:
	if hashVer >= HashVersion:
		return HashPasswordV1(password, salt) == storedHash
	return HashPassword(password, salt) == storedHash

# Reset Code
static func GenerateResetCode(length : int = DefaultResetCodeLength) -> String:
	var crypto : Crypto = Crypto.new()
	var bytes : PackedByteArray = crypto.generate_random_bytes(length)
	if bytes.size() == length:
		var code : String = ""
		for b in bytes:
			code += str(int(b) % 10)
		return code
	var rng : RandomNumberGenerator = RandomNumberGenerator.new()
	rng.randomize()
	var fallback : String = ""
	for i in length:
		fallback += str(rng.randi_range(0, 9))
	return fallback
