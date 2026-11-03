package agentic_design

import "base:intrinsics"
import NS "core:sys/darwin/Foundation"

// Secrets in the user's login Keychain (generic passwords): the cloud's device token
// (cloud.odin). One item per service and account; `keychain_set` replaces it. Readable
// only by this app (the item's access list is the app that made it).

@(private = "file")
CFTypeRef :: rawptr

foreign import security "system:Security.framework"
@(default_calling_convention = "c")
foreign security {
	kSecClass:                        CFTypeRef
	kSecClassGenericPassword:         CFTypeRef
	kSecAttrService:                  CFTypeRef
	kSecAttrAccount:                  CFTypeRef
	kSecAttrLabel:                    CFTypeRef
	kSecAttrAccessible:               CFTypeRef
	kSecAttrAccessibleAfterFirstUnlock: CFTypeRef
	kSecValueData:                    CFTypeRef
	kSecReturnData:                   CFTypeRef
	kSecMatchLimit:                   CFTypeRef
	kSecMatchLimitOne:                CFTypeRef
	SecItemAdd :: proc(attributes: CFTypeRef, result: ^CFTypeRef) -> i32 ---
	SecItemCopyMatching :: proc(query: CFTypeRef, result: ^CFTypeRef) -> i32 ---
	SecItemDelete :: proc(query: CFTypeRef) -> i32 ---
}

foreign import corefoundation "system:CoreFoundation.framework"
@(default_calling_convention = "c")
foreign corefoundation {
	kCFBooleanTrue: CFTypeRef
	CFRelease :: proc(cf: CFTypeRef) ---
}

@(private = "file")
errSecSuccess :: 0
@(private = "file")
errSecItemNotFound :: -25300

@(objc_class = "NSMutableDictionary")
Mutable_Dictionary :: struct {
	using _: NS.Object,
}

@(objc_class = "NSData")
NS_Data :: struct {
	using _: NS.Object,
}

@(private = "file")
query_for :: proc(service, account: string) -> ^NS.Object {
	d := intrinsics.objc_send(^NS.Object, Mutable_Dictionary, "dictionary")
	set :: proc(d: ^NS.Object, key, value: CFTypeRef) {
		intrinsics.objc_send(nil, d, "setObject:forKey:", NS.id(value), NS.id(key))
	}
	set(d, kSecClass, kSecClassGenericPassword)
	set(d, kSecAttrService, rawptr(ns_string(service)))
	set(d, kSecAttrAccount, rawptr(ns_string(account)))
	return d
}

// The secret, or "" when there is none (or the Keychain refused).
keychain_get :: proc(service, account: string, allocator := context.allocator) -> string {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	q := query_for(service, account)
	intrinsics.objc_send(nil, q, "setObject:forKey:", NS.id(kCFBooleanTrue), NS.id(kSecReturnData))
	intrinsics.objc_send(nil, q, "setObject:forKey:", NS.id(kSecMatchLimitOne), NS.id(kSecMatchLimit))
	result: CFTypeRef
	if SecItemCopyMatching(rawptr(q), &result) != errSecSuccess || result == nil do return ""
	defer CFRelease(result)
	d := (^NS_Data)(result)
	n := intrinsics.objc_send(NS.UInteger, d, "length")
	p := intrinsics.objc_send([^]u8, d, "bytes")
	if p == nil || n == 0 do return ""
	return clone_bytes(p[:n], allocator)
}

@(private = "file")
clone_bytes :: proc(b: []u8, allocator := context.allocator) -> string {
	out := make([]u8, len(b), allocator)
	copy(out, b)
	return string(out)
}

// Stores (or replaces) the secret. False when the Keychain refused.
keychain_set :: proc(service, account, label, secret: string) -> bool {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	_ = SecItemDelete(rawptr(query_for(service, account)))
	q := query_for(service, account)
	data := intrinsics.objc_send(^NS.Object, NS_Data, "dataWithBytes:length:", raw_data(secret), NS.UInteger(len(secret)))
	intrinsics.objc_send(nil, q, "setObject:forKey:", NS.id(data), NS.id(kSecValueData))
	intrinsics.objc_send(nil, q, "setObject:forKey:", NS.id(ns_string(label)), NS.id(kSecAttrLabel))
	intrinsics.objc_send(nil, q, "setObject:forKey:", NS.id(kSecAttrAccessibleAfterFirstUnlock), NS.id(kSecAttrAccessible))
	return SecItemAdd(rawptr(q), nil) == errSecSuccess
}

keychain_delete :: proc(service, account: string) {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	_ = SecItemDelete(rawptr(query_for(service, account)))
}
