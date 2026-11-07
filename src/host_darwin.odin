package agentic_design

import "base:intrinsics"
import "core:strings"
import NS "core:sys/darwin/Foundation"

// The Mac's name as the user set it ("Kirill's MacBook Pro"), for the site's device list.
device_name :: proc() -> string {
	pool := NS.AutoreleasePool.alloc()->init()
	defer pool->drain()
	host := intrinsics.objc_send(^NS.Object, Host, "currentHost")
	name := intrinsics.objc_send(^NS.String, host, "localizedName") if host != nil else nil
	s := strings.clone(name->odinString(), context.temp_allocator) if name != nil else "Mac"
	return s[:min(len(s), 80)]
}

@(objc_class = "NSHost")
Host :: struct {
	using _: NS.Object,
}
