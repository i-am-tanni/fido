package game
import "base:runtime"
import "core:fmt"
import "core:slice"
import "core:strings"

CRLF :: "\r\n"

direction_to_string := [Direction]string {
	.Dir_None  = "None",
	.Dir_North = "North",
	.Dir_South = "South",
	.Dir_East  = "East",
	.Dir_West  = "West",
}

Msg_Payload :: struct {
	actor_name:     string,
	actor_he:       string,
	actor_his:      string,
	actor_him:      string,
	actor_himself:  string,
	victim_name:    string,
	victim_he:      string,
	victim_his:     string,
	victim_him:     string,
	victim_himself: string,
	object_name:    string,
}

try_look :: proc(g_mem: ^GameMem, event: Ev_Look) -> bool {
	self_id := deref(g_mem, event.actor) or_return
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	// output to connection if available
	if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, self_id); has_conn {
		sb := string_builder(4096) or_return
		room_show := sparse_set_get_ptr(&g_mem.show, room_id) or_return
		contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return
		exits, _ := sparse_set_get_ptr(&g_mem.exit, room_id)
		write_string_ln(&sb, room_show.name)
		write_string_ln(&sb, room_show.long)
		write_exits(&sb, g_mem, exits, self_id)
		write_children(&sb, g_mem, contents, self_id)
		write_prompt(&sb, g_mem, self_id)
		output1(strings.to_string(sb), conn_pool[i].conn_ref)
		return true
	}
	return true
}

try_look_at :: proc(g_mem: ^GameMem, event: Ev_Look_At) -> bool {
	self_id := deref(g_mem, event.actor) or_return
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return
	_, show, found := find_1_in_room(contents, event.keywords)
	// output to connection if available
	if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, self_id); has_conn {
		sb := string_builder(4096) or_return
		write_string_ln(&sb, show.name)
		write_string_ln(&sb, show.long)
		write_prompt(&sb, g_mem, self_id)
		output1(strings.to_string(sb), conn_pool[i].conn_ref)
		return true
	}
	return true
}

try_move :: proc(g_mem: ^GameMem, event: Ev_Move) -> bool {
	self_id := deref(g_mem, event.actor) or_return
	room_id := deref(g_mem, g_mem.parent[self_id]) or_return
	exits := sparse_set_get_ptr(&g_mem.exit, room_id) or_return
	exit_data := exit_get(exits, event.exit_keyword) or_return
	child_move(g_mem, event.actor, exit_data.to_ref) or_return
	try_look(g_mem, Ev_Look{actor = event.actor, room = exit_data.to_ref}) or_return
	return true
}

try_chat :: #force_inline proc(g_mem: ^GameMem, event: NetworkEvent, msg: string) -> bool {
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

try_say :: proc(g_mem: ^GameMem, event: Ev_Say) -> bool {
	self_id := deref(g_mem, event.speaker) or_return
	show := sparse_set_get_ptr(&g_mem.show, self_id) or_return

	if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, self_id); has_conn {
		// p1 = 1st person
		p1_msg := fmt.tprintf("You say, \"{0}\"{1}", event.text, CRLF)
		output1(p1_msg, conn_pool[i].conn_ref)
	}
	// p3 = third person
	p3_msg := fmt.tprintf("{0} says, \"{1}\"{2}", show.name, event.text, CRLF)
	room_id := deref(g_mem, event.room) or_return
	room_contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return
	send_to_room(p3_msg, room_contents, {self_id})
	return true
}

try_get :: proc(g_mem: ^GameMem, event: Ev_Get) -> bool {
	self_id := deref(g_mem, event.actor) or_return
	room_id := deref(g_mem, event.room) or_return
	room_contents := sparse_set_get_ptr(&g_mem.hierarchy, room_id) or_return
	anatomy := sparse_set_get_ptr(&g_mem.anatomy, self_id) or_return
	item_id, item_show := find_1_in_room(
		room_contents,
		event.keywords,
		self_id,
		{.Portable},
	) or_return
	slot := carry_slot_get(anatomy.eq_slots[:]) or_return
	// do get
	child_rmv(g_mem, item_id)
	item_ref := ref_get(g_mem, item_id) or_return
	slot.equipped = item_ref
	// output
	actor_show := sparse_set_get_ptr(&g_mem.show, self_id) or_return
	if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, self_id); has_conn {
		p1 := fmt.tprintf("You pick up {1}.{3}", item_show.name, CRLF)
		output1(p1, conn_pool[i].conn_ref)
	}
	p3 := fmt.tprintf("{1} picks up {2}.{3}", actor_show.name, item_show.name, CRLF)
	send_to_room(p3, room_contents, {self_id})
	return true
}

write_exits :: proc(sb: ^strings.Builder, g_mem: ^GameMem, exits: ^Exitable, observer: Id) {
	exit_clean_up := false
	strings.write_string(sb, "Obvious Exits: [")

	// skip salient index
	first := true
	for &exit, i in exits.exit_list_sorted[1:] {
		// exclude and clean up exits with bad references
		if !is_ref_ok(g_mem, exit.to_ref) {
			exit.is_deleted = true
			exit_clean_up = true
			continue
		}
		// write comma separated
		if !first {
			strings.write_string(sb, ", ")
		}
		first := false
		strings.write_string(sb, direction_to_string[exit.direction])
	}
	write_string_ln(sb, "]")

	if exit_clean_up {
		// again, skip salient index
		for &exit in exits.exit_list_sorted[1:] {
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

string_builder :: #force_inline proc(
	bytes: int,
	allocator := context.temp_allocator,
) -> (
	strings.Builder,
	bool,
) {
	sb, err := strings.builder_make_len_cap(0, bytes, allocator)
	return sb, err == nil
}

send_to_room :: proc(msg: string, room_contents: ^Hierarchy, except: []Id) {
	players := make([dynamic]ConnRef, context.temp_allocator)
	it := to_child_iter(room_contents.first_kid)
	for child in next_child(&it) {
		if slice.contains(except, child) do continue
		if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, child); has_conn {
			append(&players, conn_pool[i].conn_ref)
		}
	}
	output_n(msg, players[:])
}

carry_slot_get :: proc(slots: []Eq_Slot) -> (^Eq_Slot, bool) {
	for &slot in slots {
		// if the slot can pick up an item and is currently empty
		if .Eq_Can_Carry in slot.flags && slot.equipped == {} {
			return &slot, true
		}
	}
	return nil, false
}

// find in the room via a keyword search
find_1_in_room :: proc(
	room: ^Hierarchy,
	keywords: string,
	skip_id := Id(0),
	filter: bit_set[Property] = {},
	ordinal := 0,
) -> (
	id: Id,
	show: ^Show,
	ok: bool,
) {
	keyword_ids: [dynamic; 4]u16
	assert(ordinal > 0)
	ordinal := ordinal
	terms := string_to_kw_ids(&g_mem.keyword, keywords, &keyword_ids) or_return
	it := to_child_iter(room.first_kid)
	for child in next_child(&it) {
		if !has_properties(g_mem, child, filter) || child == skip_id {
			continue
		}
		child_show, show_ok := sparse_set_get_ptr(&g_mem.show, child)
		if !show_ok || !keyword_match(terms, child_show.keyword[:]) {
			continue
		}
		// skip keyword matches until the desired ordinal is reached
		if ordinal > 0 {
			ordinal -= 1
			continue
		}
		return child, child_show, true
	}
	// not found!
	return
}

// find in the room via a keyword search
find_n_in_room :: proc(
	room: ^Hierarchy,
	keywords: string,
	skip_ids: []Id = {Id(0)},
	filter: bit_set[Property] = {},
	quantity := 1,
	allocator := context.temp_allocator,
) -> (
	[]Id,
	[]^Show,
	bool,
) {
	keyword_ids: [dynamic; 4]u16
	assert(quantity > 0)
	found := make([dynamic]Id, quantity, allocator)
	show_list := make([dynamic]^Show, quantity, allocator)
	quantity := quantity
	terms, is_ok := string_to_kw_ids(&g_mem.keyword, keywords, &keyword_ids)
	if !is_ok do return {}, {}, false
	it := to_child_iter(room.first_kid)
	for child in next_child(&it) {
		// skip keyword matches until the desired ordinal is reached
		if quantity <= 0 {
			break
		}
		if !has_properties(g_mem, child, filter) || slice.contains(skip_ids, child) {
			continue
		}
		child_show, show_ok := sparse_set_get_ptr(&g_mem.show, child)
		if !show_ok || !keyword_match(terms, child_show.keyword[:]) {
			continue
		}
		append(&found, child)
		append(&show_list, child_show)
		quantity -= 1
	}
	return found[:], show_list[:], len(found) > 0
}

Msg_Target :: enum {
	To_Char,
	To_Vict,
	// to the room but not the character nor victim
	To_Room,
}

act2 :: proc(
	template: string,
	char: Id,
	vict: Id,
	room_contents: ^Hierarchy,
	type: Msg_Target,
	payload: Msg_Payload,
) {
	switch type {
	case .To_Char:
		if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, char); has_conn {
			msg, ok := expand_tokens(template, payload)
			if !ok do return
			output1(msg, conn_pool[i].conn_ref)
		}

	case .To_Vict:
		if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, vict); has_conn {
			msg, ok := expand_tokens(template, payload)
			if !ok do return
			output1(msg, conn_pool[i].conn_ref)
		}

	case .To_Room:
		assert(room_contents != nil && room_contents.ref.id > 0)
		players := make([dynamic]ConnRef, context.temp_allocator)

		it := to_child_iter(room_contents.first_kid)
		for child in next_child(&it) {
			if child == char || child == vict do continue
			if conn_pool, i, has_conn := soa_pool_get(&g_mem.player, child); has_conn {
				append(&players, conn_pool[i].conn_ref)
			}
		}

		if len(players[:]) == 0 do return
		msg, ok := expand_tokens(template, payload)
		if !ok do return
		output_n(msg, players[:])
	}
}

expand_tokens :: proc(
	template: string,
	payload: Msg_Payload,
	allocator := context.temp_allocator,
) -> (
	s: string,
	ok: bool,
) {
	sb := string_builder(128, allocator) or_return
	i := 0
	n := len(template)
	for i < n {
		if ch := template[i]; ch != '$' {
			strings.write_byte(&sb, ch)
			i += 1
			continue
		}
		// invalid if the template ends with '$'
		assert(i + 1 < n)

		// if character is '$' and i < len(template)
		switch template[i + 1] {
		// ..and the next character is..
		case 'N':
			strings.write_string(&sb, payload.actor_name)
		case 'E':
			strings.write_string(&sb, payload.actor_he)
		case 'M':
			if strings.has_prefix(template[i:], "$MSELF") {
				strings.write_string(&sb, payload.actor_himself)
				i += 6
				continue
			}
			strings.write_string(&sb, payload.actor_him)

		case 'S':
			strings.write_string(&sb, payload.actor_his)
		case 'n':
			strings.write_string(&sb, payload.victim_name)
		case 'e':
			strings.write_string(&sb, payload.victim_he)
		case 'm':
			if strings.has_prefix(template[i:], "$mself") {
				strings.write_string(&sb, payload.victim_himself)
				i += 6
				continue
			}
			strings.write_string(&sb, payload.victim_him)

		case 's':
			strings.write_string(&sb, payload.victim_his)
		case 'o':
			strings.write_string(&sb, payload.object_name)
		case:
		// invalid? do nothing
		}
		i += 2
	}

	strings.write_string(&sb, CRLF)
	return strings.to_string(sb), true
}
