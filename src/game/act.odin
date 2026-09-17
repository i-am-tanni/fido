package game
import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync/chan"

CRLF :: "\r\n"
unknown_cmd :: "Huh?\r\n"

direction_to_string := [Direction]string {
	.Dir_None  = "None",
	.Dir_North = "North",
	.Dir_South = "South",
	.Dir_East  = "East",
	.Dir_West  = "West",
}

dispatch_cmd :: proc(g_mem: ^GameMem, self: Ref, input: Parsed_Input) -> (str: string, ok: bool) {
	switch (input.command) {
	case .Cmd_Look:
		return do_look(g_mem, self)
	case .Cmd_Go_North:
		return do_go(g_mem, self, .Dir_North)
	case .Cmd_Go_South:
		return do_go(g_mem, self, .Dir_South)
	case .Cmd_Go_East:
		return do_go(g_mem, self, .Dir_East)
	case .Cmd_Go_West:
		return do_go(g_mem, self, .Dir_West)
	case .Cmd_Invalid:
	//
	}
	buf, err := new([256]byte, context.temp_allocator)
	sb := strings.builder_from_bytes(buf[:])
	strings.write_string(&sb, unknown_cmd)
	return strings.to_string(sb), false
}

do_look :: proc(g_mem: ^GameMem, self_ref: Ref) -> (str: string, ok: bool) {
	buf, err := new([4096]byte, context.temp_allocator)
	if err != nil do return
	sb := strings.builder_from_bytes(buf[:])
	self_id := deref(g_mem, self_ref) or_return // if we need to look in the room
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	// data
	room_show := sparse_set_get_ptr(&g_mem.show, room_id) or_return
	contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return
	exits, has_exits := sparse_set_get_ptr(&g_mem.exit, room_id)
	write_string_ln(&sb, room_show.name)
	write_string_ln(&sb, room_show.long)
	write_exits(&sb, g_mem, exits, self_id)
	write_children(&sb, g_mem, contents, self_id)
	write_prompt(&sb, g_mem, self_id)
	return strings.to_string(sb), true
}

do_go :: proc(g_mem: ^GameMem, self_ref: Ref, dir: Direction) -> (str: string, ok: bool) {
	self_id := deref(g_mem, self_ref) or_return // if we need to look in the room
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	exits := sparse_set_get_ptr(&g_mem.exit, room_id) or_return
	exit_data := exit_get(exits, dir) or_return
	child_move(g_mem, self_ref, exit_data.to_ref)
	return do_look(g_mem, self_ref)
}

do_chat :: proc(g_mem: ^GameMem, self_ref: Ref, msg: string) -> bool {
	self_id := deref(g_mem, self_ref) or_return
	show, show_ok := sparse_set_get_ptr(&g_mem.show, self_id)
	msg := fmt.tprintf("{0}: {1}{2}", show.name, msg, CRLF)
	for player in g_mem.player.dense {
		chan.send(
			output_channel,
			UserOutput {
				id             = 64,
				conn_ref       = player.conn_ref,
				// no point in looking up the ref so we provide a sentinel that signals
				// that it's garbage and to be ignored
				game_ref       = Ref{0, 0},
				msg            = msg,
				is_terminating = false,
			},
		)
	}
	return true
}

write_exits :: proc(sb: ^strings.Builder, g_mem: ^GameMem, exits: ^Exitable, observer: Id) {
	exit_clean_up := false
	strings.write_string(sb, "Obvious Exits: [")

	exit_list_sorted := &exits.exit_list_sorted
	// skip salient index
	for i in 1 ..< len(exit_list_sorted) {
		exit := &exit_list_sorted[i]
		// exclude and clean up exits with bad references
		_, ok := deref(g_mem, exit.to_ref)
		if _, ok := deref(g_mem, exit.to_ref); !ok {
			exit.is_deleted = true
			exit_clean_up = true
			continue
		}
		// write comma separated
		if i > 1 {
			strings.write_string(sb, ", ")
		}
		strings.write_string(sb, direction_to_string[exit.direction])
	}
	write_string_ln(sb, "]")

	if exit_clean_up {
		// again, skip salient index
		for i in 1 ..< len(exit_list_sorted) {
			exit := &exit_list_sorted[i]
			if exit.is_deleted {
				exit_rmv(exits, exit.direction)
			}
		}
	}
}

write_children :: proc(sb: ^strings.Builder, g_mem: ^GameMem, contents: ^Hierarchy, observer: Id) {
	clean_up_list := make([dynamic]Id, context.temp_allocator)
	start := contents.first_kid
	// loop condition omitted cuz this is equivalent to a do-while
	for current := start;; current = current.next_sib {
		child_id, ref_ok := deref(g_mem, current.ref)
		if ref_ok && child_id != observer {
			child_show, show_ok := sparse_set_get_ptr(&g_mem.show, child_id)
			if ref_ok && show_ok {
				strings.write_string(sb, "  ")
				write_string_ln(sb, child_show.short)
			} else {
				append(&clean_up_list, current.ref.id)
			}
		}

		if current.next_sib == start do break
	}

	// clean up any invalid children
	for id in clean_up_list {
		child_rmv(g_mem, id)
	}
}

write_prompt :: proc(sb: ^strings.Builder, g_mem: ^GameMem, _self_id: Id) {
	write_string(sb, "> ")
}

write_string :: proc(sb: ^strings.Builder, s: string) -> int {
	bytes: int
	for b in transmute([]byte)s {
		// ignore any carriage returns
		if b == '\r' {
			continue
		}
		// ..and expand any newlines
		if b == '\n' {
			bytes += strings.write_string(sb, CRLF)
			continue
		}

		bytes += strings.write_byte(sb, b)
	}
	return bytes
}

write_string_ln :: proc(sb: ^strings.Builder, s: string) -> int {
	bytes := write_string(sb, s)
	bytes += strings.write_string(sb, CRLF)
	return bytes
}
