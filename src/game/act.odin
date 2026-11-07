package game
import "base:runtime"
import "core:fmt"
import "core:strings"

CRLF :: "\r\n"

direction_to_string := [Direction]string {
	.Dir_None  = "None",
	.Dir_North = "North",
	.Dir_South = "South",
	.Dir_East  = "East",
	.Dir_West  = "West",
}

do_look :: proc(g_mem: ^GameMem, event: Ev_Look) -> bool {
	self_id := deref(g_mem, event.actor) or_return
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	player, i, actor_is_player := soa_set_get(&g_mem.player, self_id)
	if actor_is_player {
		buf, err := new([4096]byte, context.temp_allocator)
		if err != nil do return false
		sb := strings.builder_from_bytes(buf[:])
		// data
		room_show := sparse_set_get_ptr(&g_mem.show, room_id) or_return
		contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return
		exits, has_exits := sparse_set_get_ptr(&g_mem.exit, room_id)
		write_string_ln(&sb, room_show.name)
		write_string_ln(&sb, room_show.long)
		write_exits(&sb, g_mem, exits, self_id)
		write_children(&sb, g_mem, contents, self_id)
		write_prompt(&sb, g_mem, self_id)
		output1(strings.to_string(sb), player[i].conn_ref)
		return true
	}

	return true
}

do_look_at :: proc(g_mem: ^GameMem, event: Ev_Look_At) -> bool {
	self_id := deref(g_mem, event.actor) or_return
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	player, i, actor_is_player := soa_set_get(&g_mem.player, self_id)

	keyword_ids: [dynamic; 4]u16
	search := string_to_kw_ids(&g_mem.keyword, event.keywords, &keyword_ids)
	room_contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return
	it := to_child_iter(room_contents.first_kid)
	if !actor_is_player {
		// NPC logic
		return true
	}
	// player logic
	for child in next_child(&it) {
		show := sparse_set_get_ptr(&g_mem.show, child) or_continue
		if keyword_match(search, show.keyword[:]) {
			buf, err := new([4096]byte, context.temp_allocator)
			assert(err == nil)
			sb := strings.builder_from_bytes(buf[:])
			write_string_ln(&sb, show.name)
			write_string_ln(&sb, show.long)
			write_prompt(&sb, g_mem, self_id)
			output1(strings.to_string(sb), player[i].conn_ref)
			break
		}
	}
	return true
}

do_move :: proc(g_mem: ^GameMem, event: Ev_Move) -> bool {
	self_id := deref(g_mem, event.actor) or_return
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	exits := sparse_set_get_ptr(&g_mem.exit, room_id) or_return
	exit_data := exit_get(exits, event.exit_keyword) or_return
	child_move(g_mem, event.actor, exit_data.to_ref) or_return
	do_look(g_mem, Ev_Look{actor = event.actor, room = exit_data.to_ref}) or_return
	return true
}

do_chat :: #force_inline proc(g_mem: ^GameMem, event: NetworkEvent, msg: string) -> bool {
	return publish(g_mem, .Ch_General, event.game_ref, msg)
}

publish :: proc(g_mem: ^GameMem, topic: Ch_Topic, ref: Ref, msg: string) -> bool {
	self_id := deref(g_mem, ref) or_return
	entity := sparse_set_get_ptr(&g_mem.entity, self_id) or_return
	if topic not_in entity.subscriptions {
		output1_via_ref(g_mem, ref, "You are not subscribed to that channel.\r\n")
		return true
	}
	show := sparse_set_get_ptr(&g_mem.show, self_id) or_return
	chat_msg := fmt.tprintf("{0}: {1}{2}", show.name, msg, CRLF)
	output_n(chat_msg, g_mem.channel[topic][:])
	return true
}

do_say :: proc(g_mem: ^GameMem, event: Ev_Say) -> bool {
	self_id := deref(g_mem, event.speaker) or_return
	show, show_ok := sparse_set_get_ptr(&g_mem.show, self_id)

	player, i, is_player := soa_set_get(&g_mem.player, self_id)
	if is_player {
		// p1 = 1st person
		p1_msg := fmt.tprintf("You say, \"{0}\"{1}", event.text, CRLF)
		output1(p1_msg, player[i].conn_ref)
	}
	// p3 = third person
	p3_msg := fmt.tprintf("{0} says, \"{1}\"{2}", show.name, event.text, CRLF)
	room_id := deref(g_mem, event.room) or_return
	room_contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return

	players := make([dynamic]ConnRef, context.temp_allocator)
	it := to_child_iter(room_contents.first_kid)
	for child in next_child(&it) {
		if child != self_id {
			index, is_player := soa_set_index(&g_mem.player, child)
			if is_player {
				append(&players, player[index].conn_ref)
			}
		}
	}
	output_n(p3_msg, players[:])
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
		if !is_ref_ok(g_mem, exit.to_ref) {
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
	it := to_child_iter(contents.first_kid, observer)
	for child in next_child(&it) {
		child_show := sparse_set_get_ptr(&g_mem.show, child) or_continue
		strings.write_string(sb, "  ")
		write_string_ln(sb, child_show.short)
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
