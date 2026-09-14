package game

import "core:container/queue"
import "core:slice"
import "core:sync/chan"

deref :: proc(state: ^GameMem, ref: Ref) -> (id: Id, is_valid: bool) {
	if ref.id == 0 do return
	entity := sparse_set_get_ptr(&state.entity, ref.id) or_return
	return ref.id, ref == entity.ref
}

entity_new_assign_id :: proc(g_mem: ^GameMem) -> Ref {
	id, ok := queue.pop_front_safe(&g_mem.free_list)
	if !(ok) {
		id = Id(len(g_mem.entity.dense))
	}
	return entity_new(g_mem, id)
}

entity_new :: proc(g_mem: ^GameMem, id: Id) -> Ref {
	entity := Entity {
		ref = Ref{id = id},
	}
	ptr, is_ok := sparse_set_try_insert(&g_mem.entity, id, entity)

	// if insertion fails because there already is data there
	if (!is_ok) {
		idx := g_mem.entity.sparse[id]
		ptr := &g_mem.entity.dense[idx]
		ptr.ref.generation += 1
	}

	return ptr.ref
}

entity_rmv_soft :: proc(g_mem: ^GameMem, ref: Ref) -> bool {
	id := deref(g_mem, ref) or_return
	entity, _ := sparse_set_get_ptr(&g_mem.entity, id)
	entity.ref.generation += 1
	queue.push_back(&g_mem.free_list, ref.id)
	for prop in entity.property_set {
		prop_rmv(g_mem, ref, prop)
	}
	return true
}

entity_rmv_hard :: proc(g_mem: ^GameMem, ref: Ref) -> bool {
	id := deref(g_mem, ref) or_return
	entity, _ := sparse_set_get_ptr(&g_mem.entity, id)
	for prop in entity.property_set {
		prop_rmv(g_mem, ref, prop)
	}
	sparse_set_remove(&g_mem.entity, ref.id)
	queue.push_back(&g_mem.free_list, ref.id)
	for prop in entity.property_set {
		prop_rmv(g_mem, ref, prop)
	}
	return true
}

has_property :: #force_inline proc(g_mem: ^GameMem, property: Property, id: Id) -> bool {
	entity, _ := sparse_set_get_ptr(&g_mem.entity, id)
	return property in entity.property_set
}

prop_add :: proc(g_mem: ^GameMem, ref: Ref, data: PropertyData) -> bool {
	id := deref(g_mem, ref) or_return
	property := data_to_property(data)
	if has_property(g_mem, property, id) do return false
	switch val in data {
	case Hierarchy:
		sparse_set_try_insert(&g_mem.hierarchy, id, val)
	case Show:
		sparse_set_try_insert(&g_mem.show, id, val)
	case Health:
		sparse_set_try_insert(&g_mem.health, id, val)
	case Exitable:
		sparse_set_try_insert(&g_mem.exit, id, val)
	case Player:
		sparse_set_try_insert(&g_mem.player, id, val)
	}

	slot, ok := sparse_set_get_ptr(&g_mem.entity, id)
	if !ok do return false
	slot.property_set |= {property}
	return true
}

prop_rmv :: proc(g_mem: ^GameMem, ref: Ref, property: Property) -> bool {
	id := deref(g_mem, ref) or_return
	if !has_property(g_mem, property, id) do return false

	switch property {
	case .Hierarchy:
		child_prop_rmv(g_mem, id)
	case .Show:
		sparse_set_remove(&g_mem.show, id)
	case .Health:
		sparse_set_remove(&g_mem.health, id)
	case .Exitable:
		sparse_set_remove(&g_mem.exit, id)
	case .Player:
		sparse_set_remove(&g_mem.player, id)
	case .None: // do nothing
	}
	slot, ok := sparse_set_get_ptr(&g_mem.entity, id)
	if !ok do return false
	slot.property_set |= {property}

	return true
}

data_to_property :: proc(data: PropertyData) -> Property {
	switch tag in data {
	case Hierarchy:
		return .Hierarchy
	case Show:
		return .Show
	case Health:
		return .Health
	case Exitable:
		return .Exitable
	case Player:
		return .Player
	case:
		return .None
	}
}

hierarchy_init :: proc(g_mem: GameMem, hierarchy: ^Hierarchy) {
	sentinel := &g_mem.hierarchy.dense[0]
	hierarchy^ = {
		first_kid = sentinel,
		next_sib  = sentinel,
		prev_sib  = sentinel,
	}
}

child_move :: proc(g_mem: ^GameMem, child_ref: Ref, to_parent: Ref) -> bool {
	id := deref(g_mem, child_ref) or_return
	child_rmv(g_mem, id) or_return
	child_prepend(g_mem, to_parent, child_ref) or_return
	return true
}

child_prop_rmv :: proc(g_mem: ^GameMem, id: Id) -> bool {
	ok := child_rmv(g_mem, id)
	g_mem.parent[id] = {}
	sparse_set_remove(&g_mem.hierarchy, id)
	return ok
}

child_rmv :: proc(g_mem: ^GameMem, id: Id) -> bool {
	child := sparse_set_get_ptr(&g_mem.hierarchy, id) or_return
	parent_id, _ := deref(g_mem, g_mem.parent[id])
	parent, _ := sparse_set_get_ptr(&g_mem.hierarchy, parent_id)

	sentinel := &g_mem.hierarchy.dense[0]
	head := parent.first_kid
	// if the head of the list is child, get the new head
	new_head := head == child ? child.next_sib : head
	// ..and if new head is still the child, list has only one member.
	// Default to sentinel
	parent.first_kid = new_head == child ? sentinel : new_head
	child.prev_sib.next_sib = child.next_sib
	child.next_sib.prev_sib = child.prev_sib
	return true
}

// Insert child as the first kid of the parent
//
child_prepend :: proc(g_mem: ^GameMem, parent_ref: Ref, child_ref: Ref) -> bool {
	// you can't contain yourself!
	if parent_ref == child_ref do return false

	parent_id := deref(g_mem, parent_ref) or_return
	child_id := deref(g_mem, child_ref) or_return
	child := sparse_set_get_ptr(&g_mem.hierarchy, child_id) or_return
	parent := sparse_set_get_ptr(&g_mem.hierarchy, parent_id) or_return

	head := parent.first_kid
	sentinel := &g_mem.hierarchy.dense[0]

	is_empty := head == sentinel

	child.next_sib = is_empty ? child : head
	child.prev_sib = is_empty ? child : head.prev_sib
	child.prev_sib.next_sib = child
	child.next_sib.prev_sib = child
	parent.first_kid = child
	g_mem.parent[child_id] = parent_ref
	return true
}

// Insert child as the last kid of the parent
//
child_append :: proc(g_mem: ^GameMem, parent_ref: Ref, child_ref: Ref) -> bool {
	// you can't contain yourself!
	if parent_ref == child_ref do return false

	parent_id := deref(g_mem, parent_ref) or_return
	child_id := deref(g_mem, child_ref) or_return

	child := sparse_set_get_ptr(&g_mem.hierarchy, child_id) or_return
	parent := sparse_set_get_ptr(&g_mem.hierarchy, parent_id) or_return

	sentinel := &g_mem.hierarchy.dense[0]
	head := parent.first_kid

	is_empty := head == sentinel
	child.next_sib = is_empty ? child : head
	child.prev_sib = is_empty ? child : head.prev_sib
	child.next_sib.prev_sib = child
	child.prev_sib.next_sib = child

	parent.first_kid = is_empty ? child : head
	g_mem.parent[child_id] = parent_ref

	return true
}

exit_add :: proc(sparse_set: ^SparseSet(Exitable), id: Id, exit_data: ExitData) -> bool {
	if exit_data.direction == .Dir_None do return false
	data, ok := sparse_set_get_ptr(sparse_set, id)
	// if exit property does not exist for this id
	if !ok {
		new := Exitable{}
		append(&new.exit_list_sorted, ExitData{})
		sparse_set_try_insert(sparse_set, id, new)
		data, ok = sparse_set_get_ptr(sparse_set, id)
	}

	// since exits are sorted, search for index to inject
	idx, found := slice.binary_search_by(
	data.exit_list_sorted[:],
	exit_data.direction,
	proc(it: ExitData, key: Direction) -> slice.Ordering {
		// sort exits in reverse order (1 == largest, etc.)
		if int(it.direction) > int(key) do return .Greater
		if int(it.direction) < int(key) do return .Less
		return .Equal
	},
	)

	if (found) {
		data.exit_list_sorted[idx] = exit_data
		return true
	}
	data.sparse[exit_data.direction] = u8(idx)
	inject_at(&data.exit_list_sorted, idx, exit_data)

	return true
}

exit_rmv :: proc(data: ^Exitable, direction: Direction) -> bool {
	idx := data.sparse[direction]
	data.sparse[direction] = 0
	// ordered removal invalidates our sparse indexes, but retains sorting
	ordered_remove(&data.exit_list_sorted, idx)
	//..so shift the sparse values as well
	len := u8(len(data.exit_list_sorted))
	for i := idx; i < len; i += 1 {
		elem := data.exit_list_sorted[i]
		data.sparse[elem.direction] -= 1
	}
	return true
}

exit_get :: proc(exits: ^Exitable, direction: Direction) -> (^ExitData, bool) {
	idx := exits.sparse[direction]
	if idx == 0 do return nil, false
	exit_data := &exits.exit_list_sorted[idx]
	return exit_data, true
}

is_player :: proc(g_mem: GameMem, id: Id) -> bool {
	return g_mem.player.sparse[id] > 0
}

room_new :: proc(g_mem: ^GameMem, room: Room) -> Ref {
	ref := entity_new(g_mem, room.id)
	hierarchy := Hierarchy{}
	hierarchy_init(g_mem^, &hierarchy)
	hierarchy.ref = ref
	exits := Exitable{}
	append(&exits.exit_list_sorted, ExitData{})
	prop_add(g_mem, ref, hierarchy)
	prop_add(g_mem, ref, Show{room.name, room.short, room.long})
	prop_add(g_mem, ref, exits)
	return ref
}

player_new :: proc(g_mem: ^GameMem, data: Player) -> Ref {
	ref := entity_new_assign_id(g_mem)
	hierarchy := Hierarchy{}
	hierarchy_init(g_mem^, &hierarchy)
	hierarchy.ref = ref
	prop_add(g_mem, ref, hierarchy)
	prop_add(g_mem, ref, data)
	prop_add(g_mem, ref, Show{short = "A player is here.", long = "", name = "Player"})
	return ref
}

send :: proc(g_mem: ^GameMem, ref: Ref, bytes: string) -> bool {
	id := deref(g_mem, ref) or_return
	player := sparse_set_get_ptr(&g_mem.player, id) or_return
	chan.send(
		output_channel,
		UserOutput {
			id = 64,
			conn_ref = player.conn_ref,
			game_ref = ref,
			msg = bytes,
			is_terminating = false,
		},
	)
	return true
}
