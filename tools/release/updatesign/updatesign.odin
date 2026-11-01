// Update signing for Agentic Design releases (docs/releasing.md). The app verifies with
// the same Ed25519 code (src/update.odin), so there is one implementation of both sides.
//
//   updatesign keygen <private-key-file>      new key: the seed (base64) into the file,
//                                             mode 600; prints the public key (base64)
//   updatesign pubkey                         the public key of the signing key
//   updatesign manifest <version> <url> <zip> <notes-file> <out.json>
//                                             write the update manifest: version, url,
//                                             sha256 and size of the zip, notes
//   updatesign sign <file>                    write <file>.sig: the Ed25519 signature
//                                             (base64) of the file's bytes
//   updatesign verify <public-key> <file>     check <file>.sig; exit 1 if it fails
//
// The signing key is read from $UPDATE_SIGNING_KEY (base64 seed), or from the file named
// by $UPDATE_SIGNING_KEY_FILE. It never lives in the repository.
package updatesign

import "core:crypto"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:encoding/hex"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"

main :: proc() {
	args := os.args
	if len(args) < 2 do usage()
	switch args[1] {
	case "keygen":
		if len(args) != 3 do usage()
		keygen(args[2])
	case "pubkey":
		key := load_key()
		pub: [ed25519.PUBLIC_KEY_SIZE]byte
		ed25519.private_key_public_bytes(&key, pub[:])
		fmt.println(base64.encode(pub[:]))
	case "manifest":
		if len(args) != 7 do usage()
		manifest(args[2], args[3], args[4], args[5], args[6])
	case "sign":
		if len(args) != 3 do usage()
		sign(args[2])
	case "verify":
		if len(args) != 4 do usage()
		if !verify(args[2], args[3]) {
			fmt.eprintln("updatesign: signature does NOT match", args[3])
			os.exit(1)
		}
		fmt.println("ok", args[3])
	case:
		usage()
	}
}

usage :: proc() -> ! {
	fmt.eprintln("usage: updatesign keygen <file> | pubkey | manifest <version> <url> <zip> <notes> <out> | sign <file> | verify <public-key> <file>")
	os.exit(2)
}

fail :: proc(msg: string, args: ..any) -> ! {
	fmt.eprintfln(msg, ..args)
	os.exit(1)
}

keygen :: proc(path: string) {
	if os.exists(path) do fail("updatesign: %s exists; not overwriting a signing key", path)
	seed: [ed25519.PRIVATE_KEY_SIZE]byte
	crypto.rand_bytes(seed[:])
	key: ed25519.Private_Key
	if !ed25519.private_key_set_bytes(&key, seed[:]) do fail("updatesign: bad seed")
	text := strings.concatenate({base64.encode(seed[:]), "\n"})
	fd := posix.open(strings.clone_to_cstring(path), {.CREAT, .WRONLY, .EXCL}, {.IRUSR, .IWUSR})
	if fd < 0 do fail("updatesign: cannot create %s", path)
	posix.write(fd, raw_data(text), uint(len(text)))
	posix.close(fd)
	pub: [ed25519.PUBLIC_KEY_SIZE]byte
	ed25519.private_key_public_bytes(&key, pub[:])
	fmt.println(base64.encode(pub[:]))
}

load_key :: proc() -> (key: ed25519.Private_Key) {
	text := os.get_env("UPDATE_SIGNING_KEY", context.allocator)
	if text == "" {
		if path := os.get_env("UPDATE_SIGNING_KEY_FILE", context.allocator); path != "" {
			data, err := os.read_entire_file(path, context.allocator)
			if err != nil do fail("updatesign: cannot read %s", path)
			text = string(data)
		}
	}
	if text == "" do fail("updatesign: set UPDATE_SIGNING_KEY (base64 seed) or UPDATE_SIGNING_KEY_FILE")
	seed, err := base64.decode(strings.trim_space(text))
	if err != nil || len(seed) != ed25519.PRIVATE_KEY_SIZE do fail("updatesign: the signing key is not a base64 32-byte seed")
	if !ed25519.private_key_set_bytes(&key, seed) do fail("updatesign: bad signing key")
	return
}

manifest :: proc(version, url, zip, notes_path, out: string) {
	data, err := os.read_entire_file(zip, context.allocator)
	if err != nil do fail("updatesign: cannot read %s", zip)
	digest := hash.hash_bytes(.SHA256, data)
	notes := ""
	if notes_path != "-" {
		n, nerr := os.read_entire_file(notes_path, context.allocator)
		if nerr != nil do fail("updatesign: cannot read %s", notes_path)
		notes = strings.trim_space(string(n))
	}
	b := strings.builder_make()
	strings.write_string(&b, "{\n")
	fmt.sbprintf(&b, "  \"version\": %q,\n", version)
	fmt.sbprintf(&b, "  \"url\": %q,\n", url)
	fmt.sbprintf(&b, "  \"sha256\": %q,\n", string(hex.encode(digest)))
	fmt.sbprintf(&b, "  \"size\": %d,\n", len(data))
	fmt.sbprintf(&b, "  \"arch\": \"arm64\",\n")
	fmt.sbprintf(&b, "  \"minimum_macos\": \"14.0\",\n")
	fmt.sbprintf(&b, "  \"date\": %q,\n", date_now())
	strings.write_string(&b, "  \"notes\": ")
	json_string(&b, notes)
	strings.write_string(&b, "\n}\n")
	if os.write_entire_file(out, strings.to_string(b)) != nil do fail("updatesign: cannot write %s", out)
	fmt.println("wrote", out)
}

sign :: proc(path: string) {
	key := load_key()
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do fail("updatesign: cannot read %s", path)
	sig: [ed25519.SIGNATURE_SIZE]byte
	ed25519.sign(&key, data, sig[:])
	out := strings.concatenate({path, ".sig"})
	if os.write_entire_file(out, strings.concatenate({base64.encode(sig[:]), "\n"})) != nil do fail("updatesign: cannot write %s", out)
	fmt.println("wrote", out)
}

verify :: proc(pub_b64, path: string) -> bool {
	pub_bytes, perr := base64.decode(strings.trim_space(pub_b64))
	if perr != nil do return false
	pub: ed25519.Public_Key
	if !ed25519.public_key_set_bytes(&pub, pub_bytes) do return false
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil do return false
	sig_text, serr := os.read_entire_file(strings.concatenate({path, ".sig"}), context.allocator)
	if serr != nil do return false
	sig, derr := base64.decode(strings.trim_space(string(sig_text)))
	if derr != nil || len(sig) != ed25519.SIGNATURE_SIZE do return false
	return ed25519.verify(&pub, data, sig)
}

date_now :: proc() -> string {
	buf: [time.MIN_YYYY_DATE_LEN]u8
	return strings.clone(time.to_string_yyyy_mm_dd(time.now(), buf[:]))
}

json_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"': strings.write_string(b, `\"`)
		case '\\': strings.write_string(b, `\\`)
		case '\n': strings.write_string(b, `\n`)
		case '\r':
		case '\t': strings.write_string(b, `\t`)
		case:
			if r < 0x20 do fmt.sbprintf(b, "\\u%04x", r)
			else do strings.write_rune(b, r)
		}
	}
	strings.write_byte(b, '"')
}
