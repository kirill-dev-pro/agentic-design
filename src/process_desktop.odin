#+build !js
package agentic_design

import "core:strconv"
import "core:sys/posix"

// A numeric agent id is the MCP proxy's process id: true once that process has ended.
// Other ids (tests, other front ends) never count as ended.
agent_process_gone :: proc(id: string) -> bool {
	pid, ok := strconv.parse_int(id)
	if !ok || pid <= 0 do return false
	if posix.kill(posix.pid_t(pid), posix.Signal(0)) == .OK do return false
	return posix.errno() == .ESRCH
}
